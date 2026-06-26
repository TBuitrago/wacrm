-- ============================================================
-- 027_invite_only_signup.sql — make self-service signup invite-only
--
-- Problem
--   `/signup` calls supabase.auth.signUp() directly with the public
--   anon key, and the 017 `handle_new_user` trigger bootstraps a
--   fresh account for EVERY new auth.users row. Net effect: anyone
--   on the internet can self-register a brand-new account. Hiding
--   the signup form in the UI is not enough — the anon key is in the
--   client bundle, so a direct GoTrue call would still succeed.
--
-- Fix (enforced at the DB, the only choke point both the UI and a
-- raw API call must pass through)
--   `handle_new_user` now REFUSES to create the account/profile —
--   and, by raising inside the AFTER INSERT trigger, rolls back the
--   auth.users insert so signUp fails — unless ONE of these holds:
--
--     1. A valid invitation. The signup form forwards the plaintext
--        invite token in user_metadata (`invite_token`). We hash it
--        the same way the redeem path does (SHA-256 hex) and require
--        a still-pending, unexpired row in `account_invitations`.
--
--     2. An admin bypass. `raw_app_meta_data->>'invite_bypass' =
--        'true'`. app_metadata can ONLY be set server-side (service
--        role / Supabase admin API), never by a client signUp call,
--        so this is a safe escape hatch for the owner to onboard a
--        genuinely new account from the Supabase dashboard:
--          supabase.auth.admin.createUser({
--            email, password, email_confirm: true,
--            app_metadata: { invite_bypass: true },
--          })
--
--   Everything else (the unchanged account + profile bootstrap, the
--   swallow-and-warn around it, the redeem flow that later moves an
--   invited user out of their personal account) is preserved.
--
-- Existing users are unaffected — the trigger only fires on NEW
-- auth.users inserts.
--
-- Idempotent — safe to run multiple times.
-- ============================================================

-- `digest()` lives in pgcrypto. On Supabase the extension is
-- pre-installed in the `extensions` schema; on a vanilla Postgres
-- (local dev) this creates it in the default schema. Either way the
-- function below pins `extensions` into its search_path so the call
-- resolves regardless of where pgcrypto landed. (A schema named in
-- search_path that doesn't exist is silently ignored, so this is
-- safe on both.)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_full_name   TEXT;
  v_account_id  UUID;
  v_invite_tok  TEXT;
  v_invite_hash TEXT;
  v_invite_ok   BOOLEAN := FALSE;
  v_bypass      BOOLEAN := FALSE;
BEGIN
  -- ----- Invite-only gate -------------------------------------
  -- Kept OUTSIDE the bootstrap's exception handler below so the
  -- RAISE propagates and aborts the auth.users insert. (The 017
  -- version wrapped the whole body in `EXCEPTION WHEN OTHERS ...
  -- RETURN NEW`, which would have swallowed this gate.)
  v_bypass := COALESCE(NEW.raw_app_meta_data->>'invite_bypass', '') = 'true';

  IF NOT v_bypass THEN
    v_invite_tok := NULLIF(NEW.raw_user_meta_data->>'invite_token', '');
    IF v_invite_tok IS NOT NULL THEN
      v_invite_hash := encode(digest(v_invite_tok, 'sha256'), 'hex');
      SELECT EXISTS (
        SELECT 1
        FROM public.account_invitations
        WHERE token_hash = v_invite_hash
          AND accepted_at IS NULL
          AND expires_at > NOW()
      ) INTO v_invite_ok;
    END IF;

    IF NOT v_invite_ok THEN
      -- 42501 = insufficient_privilege. Surfaces to the client as a
      -- failed signup; the /signup page only renders its form when an
      -- invite token is present, so a legitimate user never trips this.
      RAISE EXCEPTION 'Registration is invite-only'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- ----- Account + profile bootstrap (unchanged from 017) -----
  v_full_name := COALESCE(NEW.raw_user_meta_data->>'full_name', '');

  BEGIN
    INSERT INTO public.accounts (name, owner_user_id)
    VALUES (COALESCE(NULLIF(v_full_name, ''), NEW.email, 'My account'), NEW.id)
    RETURNING id INTO v_account_id;

    INSERT INTO public.profiles (user_id, full_name, email, account_id, account_role)
    VALUES (NEW.id, v_full_name, NEW.email, v_account_id, 'owner');
  EXCEPTION WHEN OTHERS THEN
    -- A transient hiccup here must not block an otherwise-valid
    -- (invited / bypassed) signup; 017's healing backfill recreates
    -- a missing profile. Note this is a NESTED handler — it cannot
    -- catch the gate's RAISE above.
    RAISE WARNING 'Failed to bootstrap account/profile for user %: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;

ALTER FUNCTION public.handle_new_user() OWNER TO postgres;

-- Recreate the trigger so a fresh DB (or one where it was dropped)
-- ends up wired to the function. CREATE OR REPLACE above already
-- updated the body for existing installs; this keeps the migration
-- self-contained.
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

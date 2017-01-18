{- | This module takes care of the authentication of a user

-}

{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Web.Gathering.Actions.Auth where

import Web.Gathering.Types
import Web.Gathering.Config
import Web.Gathering.Database
import Web.Gathering.HashPassword
import Web.Gathering.Forms.Utils
import Web.Gathering.Actions.Utils
import Web.Gathering.Workers.SendEmails
import qualified Web.Gathering.Forms.Sign as FS

import Data.Int (Int32)
import Data.Monoid
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Control.Exception
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Hasql.Session as Sql (run)
import Data.HVect (HVect(..), ListContains, NotInList, findFirst)

import Web.Spock
import Web.Spock.Digestive

import Lucid (p_, class_)

-----------
-- Hooks --
-----------

-- Hooks are the context of the app and provides us
-- a type safe way to check we don't call functions we are not supposed to
-- call. For example, Only guests should be able to sign-in or sign-up
--
-- for more info consult this guide: https://www.spock.li/2015/04/19/type-safe_routing.html


-- | A label for the guest only hook to mark that the user is not logged in
data IsGuest = IsGuest
  deriving (Show, Eq, Ord)

-- | A label for the admin hook to mark that the user is an administrator
data IsAdmin = IsAdmin
  deriving (Show, Eq, Ord)


-- | Verifies that the user is a guest to the site.
--   If they aren't it will redirect to root
guestOnlyHook :: Action (HVect xs) (HVect (IsGuest ': xs))
guestOnlyHook =
  maybeUser $ \mUser -> do
    oldCtx <- getContext
    case mUser of
      Nothing -> return (IsGuest :&: oldCtx)
      Just _ -> redirect "/"

-- | Checks that the user is logged in.
--   If they aren't it will display an error message
authHook :: Action (HVect xs) (HVect (User ': xs))
authHook =
  maybeUser $ \mUser -> do
    oldCtx <- getContext
    case mUser of
      Nothing ->
        redirect "/signin"
      Just val ->
        pure (val :&: oldCtx)

-- | Checks that the user is an admin.
--   If they aren't it will display an error message
adminHook :: ListContains n User xs => Action (HVect xs) (HVect (IsAdmin ': xs))
adminHook = do
  user <- fmap findFirst getContext
  oldCtx <- getContext
  if userIsAdmin user
    then pure (IsAdmin :&: oldCtx)
    else text "You don't have permissions to view this, sorry,"


-------------
-- Actions --
-------------

-- Actions describe the actions to perform when a user wants to sign-in/up/out


-- | Describe the action to do when a user wants to sign into the system:
--
--   Will present the sign-in form and will take care of the validation,
--   will query the database for validation, will insert the new session
--   and will write it in the session state on success
--
signInAction :: (ListContains n IsGuest xs, NotInList User xs ~ 'True) => Action (HVect xs) ()
signInAction = do
  title <- cfgTitle . appConfig <$> getState
  let
    -- | Display the form to the user
    formView mErr view = do
      form <- secureForm "signin" FS.signinFormView view
      formViewer title "Sign-in" form mErr

  -- Run the form
  form <- runForm "" FS.signinForm
  -- validate the form.
  -- Nothing means failure. will display the form view back to the user when validation fails.
  case form of
    (view, Nothing) ->
      formView Nothing view
    -- If basic validation of fields succeeds, continue to check validation against db

    (view, Just FS.Signin{sinLogin, sinPassword}) -> do
      -- Query the db for a match for the login
      -- (will check if sinLogin match either the user name or email)
      maybeUserAndPass <- runQuery $ Sql.run (getUserLogin sinLogin sinLogin)
      case maybeUserAndPass of
        -- @TODO this is an internal error that we should take care of internally
        Left err -> do
          text $ T.pack (show err)

        Right Nothing ->
          formView (pure $ p_ [ class_ "error" ] "Invalid user name/email.") view

        Right (Just (user, pass)) -> do
          if verifyPassword (T.encodeUtf8 sinPassword) pass
            then do -- success - create the session for the user
              makeSession (userId user) $
                redirect "/"
            else
              formView (pure $ p_ [ class_ "error" ] "Invalid password.") view

-- | Describe the action to do when a user wants to sign up for the system:
--
--   Will present the sign-up form and will take care of the validation,
--   will query the database for validation, will insert the new session
--   and will write it in the session state on success
--
signUpAction :: (ListContains n IsGuest xs, NotInList User xs ~ 'True) => Action (HVect xs) ()
signUpAction = do
  title <- cfgTitle . appConfig <$> getState
  let
    -- | Display the form to the user
    formView mErr view = do
      form <- secureForm "signup" FS.signupFormView view
      formViewer title "Sign-up" form mErr

  -- Run the form
  form <- runForm "" FS.signupForm
  -- validate the form.
  -- Nothing means failure. will display the form view back to the user when validation fails.
  case form of
    (view, Nothing) ->
      formView Nothing view

    -- Case for bots
    (_, Just (FS.Signup { supUsername, supSpamHoneyPot }))
      | not (T.null supSpamHoneyPot) -> do
        text $ "Success! Now logged in as: " <> supUsername -- gotcha!

    -- Case for humans
    (view, Just (FS.Signup uname umail pass passConfirm notify _)) -> do
      -- Query the db for a match for the login
      -- will check if the users' requested name or email already exists
      maybeUserAndPass <- runQuery $ Sql.run (getUserLogin uname umail)
      case maybeUserAndPass of
        -- @TODO this is an internal error that we should take care of internally
        Left err -> do
          text $ T.pack (show err)

        Right (Just _) -> do
            formView (pure $ p_ [ class_ "error" ] "Username or email already exists.") view

        Right Nothing
          | pass /= passConfirm ->
            formView (pure $ p_ [ class_ "error" ] "Passwords do not match.") view

        -- User does not exists and passwords match. try to create a new user
        Right Nothing -> do
          hashedPass <- liftIO $ makePassword pass
          mNewUser <-
            runQuery $ Sql.run $ newUser (User 0 uname umail False notify) hashedPass
          -- @TODO this is an internal error that we should take care of internally
          case mNewUser of
            Left err ->
              text $ T.pack (show err)

            Right (Left err) ->
              text err

            Right (Right nUser) -> do
              state  <- getState
              result <- liftIO $ (pure <$> notifyVerification state nUser)
                `catch` \ex -> pure $ Left (T.pack $ show (ex :: SomeException))
              case result of
                Right () ->
                  text $ "Verification email sent to " <> userEmail nUser <> ". Note that it will expire in two days."
                    <> "\n\nPlease give it a few minutes and check your spam folder as well."

                Left err -> do
                  void . runQuery . Sql.run $ removeNewUser nUser
                  text $ "Failed to send email. Please verify your mail is valid and try again later.\n\n" <> err

signOutAction :: (ListContains n User xs) => Action (HVect xs) ()
signOutAction = do
  sess <- readSession
  case sess of
    EmptySession ->
      text "Not logged in."
    SessionId uid -> do
      writeSession EmptySession
      void $ runQuery $ Sql.run $ killSession uid -- maybe log this?
      redirect "/"

verificationAction :: (ListContains n IsGuest xs, NotInList User xs ~ 'True) => Int32 -> T.Text -> Action (HVect xs) ()
verificationAction key email = do
  result <- runQuery . Sql.run $ verifyNewUser key email
  case result of
    Left err ->
      text . T.pack $ show err

    Right (Left err) ->
      text err

    Right (Right user) ->
      makeSession (userId user) $
        redirect "/"


-----------
-- Utils --
-----------

-- | Insert the user session to the database and write in to the app state
--   So the user can continue using the website while being logged in
makeSession :: (ListContains n IsGuest xs, NotInList User xs ~ 'True)
            => UserId -> Action (HVect xs) () -> Action (HVect xs) ()
makeSession uid act = do
  sessionRegenerateId
  sessRes <- runQuery $ Sql.run $ upsertUserSession uid
  case sessRes of
    Left err -> do
      text $ T.pack (show err)
    Right _ -> do
      writeSession (SessionId uid)
      act

-- | Get the user from session if logged in and run the action by passing it the result
maybeUser :: (Maybe User -> Action ctx a) -> Action ctx a
maybeUser action = do
  sess <- readSession
  case sess of
    EmptySession ->
      action Nothing

    SessionId uid -> do
      emUser <- runQuery $ Sql.run (getUserBySession uid)
      case emUser of
        -- @TODO this is an internal error that we should take care of internally
        Left err ->
          text $ T.pack $ show err

        Right mu ->
          action mu


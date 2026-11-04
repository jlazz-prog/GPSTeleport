//! Lets GPS Teleport re-sign and reinstall itself with the user's Apple ID.
//! Signing and installing are separate calls, so no tunnel has to stay open
//! while the user is typing a 2FA code. See Vendor/idevice/gpsrefresh.h for the C API.

use std::{
    ffi::{CStr, CString, c_char, c_void},
    panic::{AssertUnwindSafe, catch_unwind},
    path::{Path, PathBuf},
    ptr::null_mut,
};

use idevice_ffi::{core_device_proxy::AdapterHandle, rsd::RsdHandshakeHandle, run_sync_local};
use isideload::{
    anisette::{AnisetteClientInfo, remote_v3::RemoteV3AnisetteProvider},
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::developer_session::DeveloperSession,
    sideload::{SideloaderBuilder, builder::MaxCertsBehavior, install::install_app_rsd},
    util::{
        callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox},
        fs_storage::FsStorage,
    },
};
use rootcause::prelude::*;

type ProgressFn = extern "C" fn(message: *const c_char, context: *mut c_void);
type CodeFn = extern "C" fn(
    sent_by_sms: bool,
    last_error: *const c_char,
    context: *mut c_void,
) -> *mut c_char;

/// What the app types instead of a code to have Apple send a text message.
const REQUEST_SMS: &str = "sms";

#[derive(Clone, Copy)]
struct Callbacks {
    progress: ProgressFn,
    code: Option<CodeFn>,
    context: *mut c_void,
}

// The Swift side of these callbacks is safe to call from any thread.
unsafe impl Send for Callbacks {}
unsafe impl Sync for Callbacks {}

impl Callbacks {
    fn progress(&self, message: &str) {
        if let Ok(message) = CString::new(message) {
            (self.progress)(message.as_ptr(), self.context);
        }
    }

    /// Blocks until the user answers. Returns None if they cancelled.
    fn ask_for_code(&self, sent_by_sms: bool, last_error: Option<&str>) -> Option<String> {
        let code = self.code?;
        let last_error = last_error.and_then(|e| CString::new(e).ok());
        let answer = code(
            sent_by_sms,
            last_error.as_ref().map_or(std::ptr::null(), |e| e.as_ptr()),
            self.context,
        );
        if answer.is_null() {
            return None;
        }
        let text = unsafe { CStr::from_ptr(answer) }.to_string_lossy().into_owned();
        unsafe { libc::free(answer.cast()) };
        Some(text)
    }
}

async fn answer_two_factor(
    callbacks: Callbacks,
    params: TwoFactorCallbackParams,
) -> Result<TwoFactorCallbackResponse, Report> {
    let sent_by_sms = params.sms;
    let last_error = params.last_error.clone();
    let answer = tokio::task::spawn_blocking(move || {
        callbacks.ask_for_code(sent_by_sms, last_error.as_deref())
    })
    .await?;

    match answer.as_deref().map(str::trim) {
        None => bail!("Sign-in was cancelled."),
        Some(REQUEST_SMS) => Ok(match params.numbers.first() {
            Some(number) => TwoFactorCallbackResponse::SendSms(number.id),
            None => TwoFactorCallbackResponse::ResendCode,
        }),
        Some(code) => Ok(TwoFactorCallbackResponse::SubmitCode(code.to_string())),
    }
}

async fn sign(
    email: &str,
    password: &str,
    bundle: PathBuf,
    storage: PathBuf,
    current_bundle_id: &str,
    callbacks: Callbacks,
) -> Result<PathBuf, Report> {
    let _ = isideload::init();
    let _ = rustls::crypto::ring::default_provider().install_default();

    callbacks.progress("Signing in to Apple…");
    let anisette = RemoteV3AnisetteProvider::default()?
        .set_serial_number("0".to_string())
        .set_storage(Box::new(FsStorage::new(storage.clone())))
        // The same override iloader uses to avoid Apple's sign-in errors.
        .set_client_info_override(Some(AnisetteClientInfo {
            client_info: "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
                .to_string(),
            user_agent: "akd/1.0 CFNetwork/811.5.4".to_string(),
        }));

    let email = email.to_lowercase();
    let mut account = AppleAccount::builder(&email)
        .anisette_provider(anisette)
        .login(password, move |params| answer_two_factor(callbacks, params))
        .await?;

    callbacks.progress("Getting a new 7-day signature…");
    let session = DeveloperSession::from_account(&mut account).await?;
    let mut sideloader =
        SideloaderBuilder::<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>::new(session, email)
            .storage(Box::new(FsStorage::new(storage)))
            .machine_name("GPS Teleport".to_string())
            // Never revoke a certificate here: that could break apps signed with it.
            .max_certs_behavior(MaxCertsBehavior::Error)
            .delete_app_after_install(false)
            .build();

    // A different Apple ID would install a second copy of the app instead of replacing this one.
    let team = sideloader.get_team().await?;
    if !current_bundle_id.ends_with(&format!(".{}", team.team_id)) {
        bail!("Sign in with the same Apple ID you used to install GPS Teleport.");
    }

    callbacks.progress("Signing GPS Teleport…");
    let (signed, _) = sideloader
        .sign_app(
            bundle,
            Some(team),
            false,
            None::<fn(f32) -> std::future::Ready<()>>,
            None,
            None,
        )
        .await?;
    Ok(signed)
}

/// Runs `work`, turning an error or a panic into a string for the app.
fn to_c_error(work: impl FnOnce() -> Result<(), String>) -> *mut c_char {
    let message = match catch_unwind(AssertUnwindSafe(work)) {
        Ok(Ok(())) => return null_mut(),
        Ok(Err(message)) => message,
        Err(_) => "The refresher crashed unexpectedly.".to_string(),
    };
    CString::new(message.replace('\0', " "))
        .unwrap_or_default()
        .into_raw()
}

unsafe fn text<'a>(pointer: *const c_char, name: &str) -> Result<&'a str, String> {
    if pointer.is_null() {
        return Err(format!("Missing {name}."));
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|_| format!("{name} isn't valid text."))
}

/// See Vendor/idevice/gpsrefresh.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gps_refresh_sign(
    email: *const c_char,
    password: *const c_char,
    bundle_path: *const c_char,
    storage_path: *const c_char,
    current_bundle_id: *const c_char,
    progress: ProgressFn,
    code: CodeFn,
    context: *mut c_void,
    signed_path: *mut *mut c_char,
) -> *mut c_char {
    to_c_error(|| {
        let email = unsafe { text(email, "Apple ID") }?;
        let password = unsafe { text(password, "password") }?;
        let bundle = PathBuf::from(unsafe { text(bundle_path, "app path") }?);
        let storage = PathBuf::from(unsafe { text(storage_path, "storage path") }?);
        let current_bundle_id = unsafe { text(current_bundle_id, "bundle ID") }?;
        let callbacks = Callbacks { progress, code: Some(code), context };

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        let signed = runtime
            .block_on(sign(email, password, bundle, storage, current_bundle_id, callbacks))
            .map_err(|e| format!("{e}"))?;

        let signed = CString::new(signed.to_string_lossy().into_owned()).map_err(|e| e.to_string())?;
        unsafe { *signed_path = signed.into_raw() };
        Ok(())
    })
}

/// See Vendor/idevice/gpsrefresh.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gps_refresh_install(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    signed_path: *const c_char,
    progress: ProgressFn,
    context: *mut c_void,
) -> *mut c_char {
    to_c_error(|| {
        if adapter.is_null() || handshake.is_null() {
            return Err("The connection to your iPhone isn't open.".to_string());
        }
        let path = PathBuf::from(unsafe { text(signed_path, "signed app path") }?);
        let callbacks = Callbacks { progress, code: None, context };

        run_sync_local(async move {
            let adapter = unsafe { &mut (*adapter).0 };
            let handshake = unsafe { &mut (*handshake).0 };
            install_app_rsd(adapter, handshake, Path::new(&path), |percent| {
                callbacks.progress(&format!("Installing… {percent}%"));
            })
            .await
            .map_err(|e| format!("{e}"))
        })
    })
}

/// See Vendor/idevice/gpsrefresh.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gps_refresh_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}

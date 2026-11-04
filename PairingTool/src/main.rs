//! GPS Teleport Pairing: run once on a PC with the iPhone plugged in. It makes the
//! RPPairing file GPS Teleport needs and copies it straight into the app.

use std::{io::Write, path::PathBuf, time::Duration};

use idevice::{
    IdeviceError, IdeviceService,
    afc::opcode::AfcFopenMode,
    house_arrest::HouseArrestClient,
    installation_proxy::InstallationProxyClient,
    lockdown::LockdownClient,
    provider::UsbmuxdProvider,
    remote_pairing::{RemotePairingLockdownService, RpPairingFile},
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice},
};

/// The name the app identifies itself by when it opens the tunnel (DeviceLink.swift).
const HOST: &str = "GPSTeleport";
const APP_BUNDLE_PREFIX: &str = "com.jlazzprog.gpsteleport";
const FILE_NAME: &str = "GPSTeleport-pairing.plist";

#[tokio::main]
async fn main() {
    println!("GPS Teleport Pairing");
    println!("====================\n");

    if let Err(message) = run().await {
        println!("\nSomething went wrong:\n  {message}");
    }

    print!("\nPress Enter to close this window.");
    let _ = std::io::stdout().flush();
    let _ = std::io::stdin().read_line(&mut String::new());
}

async fn run() -> Result<(), String> {
    let device = wait_for_iphone().await?;
    let provider = device.to_provider(UsbmuxdAddr::default(), HOST);

    let (name, version) = describe(&provider).await?;
    println!("Found {name} (iOS {version}).\n");

    trust(&device, &provider).await?;

    if developer_mode(&provider).await == Some(false) {
        println!("Note: Developer Mode is off. GPS Teleport needs it, so turn it on later:");
        println!("  Settings > Privacy & Security > Developer Mode > On (the iPhone restarts).\n");
    }

    println!("Making the pairing file...");
    let pairing = make_pairing_file(&provider).await?;
    let bytes = pairing.to_bytes();

    let saved = save_copy(&bytes);

    match install_into_app(&provider, &bytes).await {
        Ok(true) => {
            println!("\nDone! The pairing file is now inside GPS Teleport on your iPhone.");
            println!("Open GPS Teleport (close it first if it was already open) and go to Setup:");
            println!("step 3 should show a green check.");
        }
        Ok(false) => {
            println!("\nThe pairing file is made, but GPS Teleport isn't installed on this iPhone yet.");
            println!("Install it with iloader, then run this again and it'll be copied in for you.");
        }
        Err(e) => {
            println!("\nThe pairing file is made, but copying it into GPS Teleport failed ({e}).");
            println!("Get the saved copy onto your iPhone and use Setup > Import pairing file.");
        }
    }
    if let Some(path) = saved {
        println!("\nA copy is saved at:\n  {}", path.display());
        println!("Keep it private: it lets this PC's tools control your iPhone.");
    }
    Ok(())
}

async fn wait_for_iphone() -> Result<UsbmuxdDevice, String> {
    let mut told_user = false;
    loop {
        let mut mux = UsbmuxdConnection::default().await.map_err(|_| {
            "Can't reach Apple's iPhone driver on this PC.\n  \
             Install the free \"Apple Devices\" app from the Microsoft Store, open it once\n  \
             with your iPhone plugged in, then run this again."
                .to_string()
        })?;
        let devices = mux.get_devices().await.map_err(describe_error)?;
        let mut usb: Vec<UsbmuxdDevice> = devices
            .into_iter()
            .filter(|d| matches!(d.connection_type, Connection::Usb))
            .collect();

        match usb.len() {
            0 => {
                if !told_user {
                    println!("Plug your iPhone into this PC with a cable and unlock it...");
                    told_user = true;
                }
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
            1 => return Ok(usb.remove(0)),
            _ => return Err("More than one iPhone or iPad is plugged in. Unplug the others and run this again.".into()),
        }
    }
}

async fn describe(provider: &UsbmuxdProvider) -> Result<(String, String), String> {
    let mut lockdown = LockdownClient::connect(provider).await.map_err(describe_error)?;
    let name = string_value(&mut lockdown, "DeviceName").await.unwrap_or_else(|| "your iPhone".into());
    let version = string_value(&mut lockdown, "ProductVersion").await.unwrap_or_else(|| "?".into());
    Ok((name, version))
}

async fn string_value(lockdown: &mut LockdownClient, key: &str) -> Option<String> {
    lockdown
        .get_value(Some(key), None)
        .await
        .ok()?
        .as_string()
        .map(str::to_owned)
}

/// Makes sure the iPhone trusts this PC, asking the user to tap Trust if it doesn't yet.
async fn trust(device: &UsbmuxdDevice, provider: &UsbmuxdProvider) -> Result<(), String> {
    if session_works(device, provider).await {
        println!("This PC is already trusted by your iPhone.");
        return Ok(());
    }

    let mut mux = UsbmuxdConnection::default().await.map_err(describe_error)?;
    let _ = mux.delete_pair_record(&device.udid).await;
    let buid = mux.get_buid().await.map_err(describe_error)?;

    println!("On your iPhone: unlock it, tap \"Trust\", and enter your passcode.");
    let mut record = loop {
        let mut lockdown = LockdownClient::connect(provider).await.map_err(describe_error)?;
        match lockdown
            .pair(uuid::Uuid::new_v4().to_string().to_uppercase(), buid.clone(), Some(HOST))
            .await
        {
            Ok(record) => break record,
            Err(IdeviceError::PasswordProtected) => {
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
            Err(IdeviceError::UserDeniedPairing) => {
                return Err("You tapped \"Don't Trust\". Unplug the iPhone, plug it back in, and run this again.".into());
            }
            Err(e) => return Err(describe_error(e)),
        }
    };
    record.udid = Some(device.udid.clone());

    let bytes = record.serialize().map_err(describe_error)?;
    let mut mux = UsbmuxdConnection::default().await.map_err(describe_error)?;
    mux.save_pair_record(&device.udid, bytes).await.map_err(describe_error)?;
    println!("Trusted.");
    Ok(())
}

async fn session_works(device: &UsbmuxdDevice, provider: &UsbmuxdProvider) -> bool {
    let Ok(mut mux) = UsbmuxdConnection::default().await else { return false };
    let Ok(record) = mux.get_pair_record(&device.udid).await else { return false };
    let Ok(mut lockdown) = LockdownClient::connect(provider).await else { return false };
    lockdown.start_session(&record).await.is_ok()
}

async fn developer_mode(provider: &UsbmuxdProvider) -> Option<bool> {
    let mut lockdown = LockdownClient::connect(provider).await.ok()?;
    let record = UsbmuxdConnection::default().await.ok()?.get_pair_record(&provider.udid).await.ok()?;
    lockdown.start_session(&record).await.ok()?;
    lockdown
        .get_value(Some("DeveloperModeStatus"), Some("com.apple.security.mac.amfi"))
        .await
        .ok()?
        .as_boolean()
}

/// Pairs with remotepairingdeviced over the trusted USB connection. The first round
/// creates the pairing; the second confirms the iPhone kept it.
async fn make_pairing_file(provider: &UsbmuxdProvider) -> Result<RpPairingFile, String> {
    let mut file = RpPairingFile::generate(HOST);
    for _ in 0..2 {
        RemotePairingLockdownService::connect(provider)
            .await
            .map_err(describe_error)?
            .into_client(HOST)
            .map_err(describe_error)?
            // Over trusted USB the iPhone never asks for a code, so this isn't used.
            .connect(&mut file, || async { "000000".to_string() })
            .await
            .map_err(describe_error)?;
    }
    Ok(file)
}

/// Saves a copy next to this program, in case it has to be imported by hand.
fn save_copy(bytes: &[u8]) -> Option<PathBuf> {
    let path = std::env::current_exe().ok()?.parent()?.join(FILE_NAME);
    std::fs::write(&path, bytes).ok()?;
    Some(path)
}

/// Copies the file into GPS Teleport's Documents folder, where the app picks it up
/// when it opens. Returns false if the app isn't installed.
async fn install_into_app(provider: &UsbmuxdProvider, bytes: &[u8]) -> Result<bool, String> {
    let apps = InstallationProxyClient::connect(provider)
        .await
        .map_err(describe_error)?
        .get_apps(Some("User"), None)
        .await
        .map_err(describe_error)?;
    // Sideloading tools can add a suffix to the bundle ID, so match on the prefix.
    let Some(bundle_id) = apps.into_keys().find(|id| id.starts_with(APP_BUNDLE_PREFIX)) else {
        return Ok(false);
    };

    let mut afc = HouseArrestClient::connect(provider)
        .await
        .map_err(describe_error)?
        .vend_documents(bundle_id)
        .await
        .map_err(describe_error)?;
    let mut file = afc
        .open(format!("/Documents/{FILE_NAME}"), AfcFopenMode::WrOnly)
        .await
        .map_err(describe_error)?;
    file.write_entire(bytes).await.map_err(describe_error)?;
    file.close().await.map_err(describe_error)?;
    Ok(true)
}

fn describe_error(error: IdeviceError) -> String {
    match error {
        IdeviceError::PasswordProtected => "Your iPhone is locked. Unlock it and run this again.".into(),
        IdeviceError::InvalidHostID | IdeviceError::SessionInactive => {
            "Your iPhone doesn't trust this PC. Unplug it, plug it back in, tap Trust, and run this again.".into()
        }
        other => format!("{other:?}"),
    }
}

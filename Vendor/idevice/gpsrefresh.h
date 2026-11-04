// C API of RefreshCore, the in-app refresher.
#pragma once

#include <stdbool.h>
#include "idevice.h"

typedef void (*gps_refresh_progress_fn)(const char *message, void *context);

/// Asks the user for a 2FA code, blocking until they answer. Called off the main thread.
/// Returns a string from malloc: the code, or "sms" to have Apple text one instead.
/// Returns NULL if the user cancelled.
typedef char *(*gps_refresh_code_fn)(bool sent_by_sms, const char *last_error, void *context);

/// Signs in to Apple and re-signs the app bundle at `bundle_path` in place, so pass a
/// writable copy whose Info.plist has the original bundle ID, without the team ID suffix.
/// Returns NULL on success, and sets `signed_path` to the signed bundle.
/// Otherwise returns an error message. Free either string with gps_refresh_string_free.
char *gps_refresh_sign(const char *email,
                       const char *password,
                       const char *bundle_path,
                       const char *storage_path,
                       const char *current_bundle_id,
                       gps_refresh_progress_fn progress,
                       gps_refresh_code_fn code,
                       void *context,
                       char **signed_path);

/// Installs a signed app over the running one through an open tunnel. iOS closes this
/// app when the install finishes, so this may never return.
/// Returns NULL on success, otherwise an error message for gps_refresh_string_free.
char *gps_refresh_install(struct AdapterHandle *adapter,
                          struct RsdHandshakeHandle *handshake,
                          const char *signed_path,
                          gps_refresh_progress_fn progress,
                          void *context);

void gps_refresh_string_free(char *string);

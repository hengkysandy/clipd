import Foundation

/// How long after a copy a clipboard wipe still means "that was a secret".
///
/// Measured: Passwords.app wipes the clipboard 60.0s and 60.9s after a copy,
/// and no ordinary app cleared the clipboard even once in 390 seconds of real
/// use. 90 rather than 60, because "about a minute" is not exact and the
/// margin is free.
///
/// ONE number for two jobs, so they cannot drift apart:
/// - the auto-clear rule catches the newest copy if the clipboard is wiped
///   within this window;
/// - sync holds every new copy back for this long before it may leave the
///   machine, so a copy the rule is going to catch has not been uploaded yet.
///
/// If the hold were shorter than the rule, a secret could be uploaded in the
/// gap and then have to be chased out of the bucket and off the other Mac,
/// which is exactly what used to happen with a 15 second sync and a 60 second
/// wipe.
public let autoClearWindow: TimeInterval = 90

#  Onion Browser 2 Changelog

## 2.3.0

- Tor updated to 0.4.0.5
- Localization updates.
- FIXED OCSP leak by adapting code from Psiphon's Endless fork and their OCSPCache. (#178)
- Now able to share downloaded PDFs and other binary files with other apps.
- Completely overhauled bookmark management UI.
- Completely overhauled settings UI.
- Replaced own dark mode with iOS 13 dark mode support.
- Onion Browser now registers for http and https URL schemes, so is able to be the default browser
  on the device.
- Dropped special 1Password support in favor of system-wide password manager support.
- Load bridges from a stored QR code photo.
- Licensing change of Endless, the upstream browser chrome project.
- Fixed context menu in "Content Policy: strict" mode.

## 2.2.1

- New "start up in last state" feature, which remembers open tabs. (#134)
- New "open in background tab" feature (#154, #158)
- FIXED: Fixed behavior of content blocking; "strict" should now properly allow static images. (#123)
- FIXED: Corrected display issues on iPad. (#169)
- FIXED: The documented in-app purchase has been missing for a few versions.
- Updated localizations for many languages. Updated some App Store localizations and screenshots. (#163, #189, #197)

## 2.2.0

- Tor updated to 0.3.5.8.
- When the app goes to background, the preview in the app switcher is now obscured. (Issue #138)
- Improved tor stop / restart behavior when going to background. Tor now completely shuts down on 
  background and a fresh Tor launched when the app is resumed.
- FIXED: Websites with self-signed certificates may be accessed again, after warning the user of 
  the security implications. (#111)
- FIXED: Editing bridges after first launch works again. (#121, #140)
- FIXED: Using camera to import bridges from QR code works again. (#142)
- Localizations now available in Turkish. Updated localizations for most languages.

## 2.1.0

## 2.0.3

## 2.0.2

- fixes DNS leak (#112)
- fixes bootstrap on ipv6-only networks (#114, #108, old #73)
- updates built-in bridges to match latest tor browser, including an ipv6 bridge.
- adds partial persian, icelandic, and chinese (simplified) translations

## 2.0.1

- Bugfixes to get it through the App Store inspection. 

## 2.0.0

First release of the brand-new Onion Browser 2

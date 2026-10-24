# AGAP Mobile

Flutter mobile app for **AGAP – Road Incident Reporting**, part of the IT 305 final output: *Development of a Web and Mobile-Based Road Accident Reporting System*. It shares one backend and database with the AGAP web app.

This app is for **public users / reporters**. Administrators and traffic officers use the web portal; staff accounts are rejected on login in the app.

## Features

- Register, log in, and log out (session is kept on the device)
- Report an accident in 5 steps:
  1. Accident type, injury status (None / Injuries / Fatalities / Unknown), counts, and severity
  2. Vehicles involved
  3. Location: GPS, tapping the map to drop a pin, or typing latitude/longitude
  4. Title, date and time, description, and photos (camera or gallery)
  5. Review and send
- Submission confirmation with a unique report ID
- Report history and detail view: status, status history, assigned officer, official remarks, and photos
- Edit a report when staff request more information
- Clear distinction between a public-submitted report and an officially verified record
- Map tab showing your reported accidents
- In-app alerts that refresh automatically, with a banner when a new alert arrives
- Light and dark theme, profile editing

### Report statuses

Submitted, Under Review, Additional Information Required (Needs info), Verified, Assigned, In Progress, Resolved, Rejected (with the recorded reason).

## Tech stack

| Part | Technology |
|---|---|
| Mobile app | Flutter / Dart |
| Maps | `flutter_map` with Mapbox tiles (falls back to OpenStreetMap) |
| GPS | `geolocator` |
| Photos | `image_picker` |
| Networking | `http` |
| Local session | `shared_preferences` |
| Backend | REST API (deployed on Render) |

## Requirements

- Flutter SDK with Dart `^3.12.2` (see `pubspec.yaml`)
- Android Studio (or VS Code) with an Android emulator, or a physical phone
- Internet connection (the app talks to the hosted API)

## Getting started

```bash
git clone <repository-url>
cd agap_app
flutter pub get
flutter run
```

Use a full restart (`flutter run`) rather than hot reload after changing packages or native files.

## Configuration

**API URL:** set `kApiBase` in `lib/main.dart`. It currently points to the deployed backend. For a local server on the Android emulator, use `http://10.0.2.2:5000/api` (this also requires `android:usesCleartextTraffic="true"` in `AndroidManifest.xml`, which should be removed for the final build).

**Mapbox (optional):** pass your own public token when running:

```bash
flutter run --dart-define=MAPBOX_TOKEN=pk.your_token_here
```

If no valid token is set, the app uses OpenStreetMap tiles.

## Permissions

- **Android:** `INTERNET`, `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` (see `AndroidManifest.xml`)
- **iOS:** camera, photo library, and location-when-in-use descriptions are set in `ios/Runner/Info.plist`

## Project structure

```
lib/main.dart      App code (API layer, models, screens)
test/              Unit tests
android/ ios/      Platform projects
pubspec.yaml       Dependencies
```

## Testing

```bash
flutter analyze
flutter test
```

## Known limitations

- Notifications are in-app only (no push notifications).
- Evidence upload accepts photos only (JPG, PNG, or WebP, up to 5 files, 10 MB each).
- The backend is on a free Render plan and may sleep when idle, so the first request can take 30–60 seconds.

BSIT 3I, Bulacan State University – College of Information and Communications Technology
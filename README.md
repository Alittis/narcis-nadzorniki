# Narcis Nadzorniki (Demo)

Field-first phone app for recording disturbances (motenj). This demo uses a real online map (OpenStreetMap tiles) and a fake REST backend, with a local offline queue.

## What’s Included

- Map view with colored markers by recency (≤ 1 month red, ≤ 1 year orange, older blue)
- Full field form based on the PDF spec (location, accuracy, date/time, types, description, photos, observers, actions)
- Multi-select disturbance type taxonomy with notes
- Offline mode toggle with local persistence and sync queue
- Record list and detail view

## Running on Pixel 9 (Android)

1. `flutter pub get`
2. `flutter run -d <device_id>`

## Offline Mode

Open `Nastavitve` (gear icon) and enable `Offline način`. New records will be stored locally with a pending-sync badge. Turn it off and press sync to simulate upload to the mock backend.

## Notes

- The app uses OpenStreetMap tiles for the online map.
- The backend is a stub in `lib/data/remote_api.dart` that simulates network latency.
- Photos are stored as local file paths and shown in the detail screen.

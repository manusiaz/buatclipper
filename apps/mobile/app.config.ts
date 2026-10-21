// App native clipper (Android + iOS) = app.{domain} versi native: API, data, dan teks sama (identity + core).
// Identitas build dari env EAS: ANDROID_APP_PACKAGE / IOS_BUNDLE_ID (default id.clipper.app), EAS_PROJECT_ID.
import type { ConfigContext, ExpoConfig } from 'expo/config';

const pkg = process.env.ANDROID_APP_PACKAGE || 'id.clipper.app';
const bundle = process.env.IOS_BUNDLE_ID || 'id.clipper.app';

export default ({ config }: ConfigContext): ExpoConfig => ({
  ...config,
  name: 'Clipper',
  slug: 'clipper',
  scheme: 'clipper',
  version: '1.0.0',
  orientation: 'portrait',
  userInterfaceStyle: 'automatic',
  icon: '../clipper/public/icons/icon-512.png',
  ios: {
    bundleIdentifier: bundle,
    supportsTablet: false,
    infoPlist: { ITSAppUsesNonExemptEncryption: false },
  },
  android: {
    package: pkg,
    adaptiveIcon: { foregroundImage: '../clipper/public/icons/maskable-512.png', backgroundColor: '#1D5BFF' },
  },
  web: { bundler: 'metro', output: 'single', favicon: '../clipper/public/icons/icon-192.png' },
  plugins: [
    'expo-router',
    'expo-secure-store',
    'expo-font',
    'expo-web-browser',
    'expo-localization',
    ['expo-notifications', { icon: '../clipper/public/icons/badge-96.png', color: '#1D5BFF' }],
    // DS Android/iOS 01: share sheet → "Kirim clip" (link video dari app sosmed).
    [
      'expo-share-intent',
      {
        iosActivationRules: { NSExtensionActivationSupportsWebURLWithMaxCount: 1, NSExtensionActivationSupportsText: true },
        androidIntentFilters: ['text/*'],
      },
    ],
    // DS Android 01: widget saldo di home screen.
    [
      'react-native-android-widget',
      {
        widgets: [
          {
            name: 'Balance',
            label: 'Saldo Clipper',
            description: 'Saldo tersedia dan pending.',
            minWidth: '250dp',
            minHeight: '110dp',
            targetCellWidth: 4,
            targetCellHeight: 2,
            updatePeriodMillis: 1800000,
            resizeMode: 'horizontal|vertical',
          },
        ],
      },
    ],
  ],
  extra: { eas: process.env.EAS_PROJECT_ID ? { projectId: process.env.EAS_PROJECT_ID } : {} },
});

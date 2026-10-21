// App native clipper (Android + iOS) = app.{domain} versi native: API, data, dan teks sama (identity + core).
// Identitas build dari env EAS: ANDROID_APP_PACKAGE / IOS_BUNDLE_ID (default id.clipper.app), EAS_PROJECT_ID.
// Universal link / App Link: host EXPO_PUBLIC_APP_URL (https saja) ↔ app.{domain}/.well-known/{assetlinks.json,
// apple-app-site-association}; path = native-paths.json (@clipper/clipper-lib, sama dengan AASA), dipetakan app/+native-intent.tsx.
import type { ConfigContext, ExpoConfig } from 'expo/config';
import NATIVE_PATHS from '../../packages/clipper-lib/src/native-paths.json';

const pkg = process.env.ANDROID_APP_PACKAGE || 'id.clipper.app';
const bundle = process.env.IOS_BUNDLE_ID || 'id.clipper.app';
const appHost = /^https:\/\//.test(process.env.EXPO_PUBLIC_APP_URL ?? '') ? new URL(process.env.EXPO_PUBLIC_APP_URL!).host : null;
const ICONS = './assets/icons';

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
    // DS iOS 05: master 1024 terang / gelap / tinted (iOS 18), sudut dipotong sistem.
    icon: { light: `${ICONS}/ios-light.png`, dark: `${ICONS}/ios-dark.png`, tinted: `${ICONS}/ios-tinted.png` },
    infoPlist: { ITSAppUsesNonExemptEncryption: false },
    ...(appHost ? { associatedDomains: [`applinks:${appHost}`] } : {}),
  },
  android: {
    package: pkg,
    // DS Android 05: dua layer (pesawat di zona aman 66 dp) + monochrome untuk themed icon Android 13+.
    adaptiveIcon: { foregroundImage: `${ICONS}/android-foreground.png`, backgroundImage: `${ICONS}/android-background.png`, monochromeImage: `${ICONS}/android-foreground.png`, backgroundColor: '#1D5BFF' },
    // Predictive back Android 14+ (DS Motion 25 #1: layar lama mengintip saat swipe back).
    predictiveBackGestureEnabled: true,
    ...(appHost
      ? {
          intentFilters: [
            {
              action: 'VIEW',
              autoVerify: true,
              data: NATIVE_PATHS.map((p) => (p === '/' ? { scheme: 'https', host: appHost, path: '/' } : p.endsWith('/*') ? { scheme: 'https', host: appHost, pathPrefix: p.slice(0, -1) } : { scheme: 'https', host: appHost, path: p })),
              category: ['BROWSABLE', 'DEFAULT'],
            },
          ],
        }
      : {}),
  },
  web: { bundler: 'metro', output: 'single', favicon: '../clipper/public/icons/icon-192.png' },
  plugins: [
    'expo-router',
    'expo-secure-store',
    'expo-font',
    'expo-web-browser',
    'expo-localization',
    ['expo-image-picker', { photosPermission: 'Clipper memakai foto yang kamu pilih sebagai foto profil.', cameraPermission: false, microphonePermission: false }],
    ['expo-notifications', { icon: '../clipper/public/icons/badge-96.png', color: '#1D5BFF' }],
    // DS Android/iOS 01: share sheet → "Kirim clip" (link video dari app sosmed).
    [
      'expo-share-intent',
      {
        iosActivationRules: { NSExtensionActivationSupportsWebURLWithMaxCount: 1, NSExtensionActivationSupportsText: true },
        androidIntentFilters: ['text/*'],
      },
    ],
    // DS Android 05: widget 4×2 (saldo + campaign baru + review) dan 2×2 (saldo + jadwal cair) — src/widget.tsx.
    [
      'react-native-android-widget',
      {
        widgets: [
          {
            name: 'Balance',
            label: 'Saldo & campaign Clipper',
            description: 'Saldo, jadwal cair, campaign baru, dan clip yang menunggu review.',
            minWidth: '250dp',
            minHeight: '110dp',
            targetCellWidth: 4,
            targetCellHeight: 2,
            updatePeriodMillis: 1800000,
            resizeMode: 'horizontal|vertical',
          },
          {
            name: 'BalanceSmall',
            label: 'Saldo Clipper',
            description: 'Saldo tersedia dan jadwal cair.',
            minWidth: '110dp',
            minHeight: '110dp',
            targetCellWidth: 2,
            targetCellHeight: 2,
            updatePeriodMillis: 1800000,
            resizeMode: 'horizontal|vertical',
          },
        ],
      },
    ],
    // DS iOS 05: widget small (saldo) + medium (review + campaign baru) dan Live Activity "Payout" (push-to-start APNs
    // dari identity) — src/widget.ios.tsx, src/live-activity.ios.tsx.
    [
      'expo-widgets',
      {
        groupIdentifier: `group.${bundle}`,
        enablePushNotifications: true,
        widgets: [
          { name: 'ClipperBalance', displayName: 'Saldo Clipper', description: 'Saldo tersedia dan jadwal cair.', supportedFamilies: ['systemSmall'], contentMarginsDisabled: false },
          { name: 'ClipperCampaigns', displayName: 'Campaign & review', description: 'Clip yang menunggu review dan campaign baru yang cocok.', supportedFamilies: ['systemMedium'], contentMarginsDisabled: false },
        ],
      },
    ],
  ],
  extra: { eas: process.env.EAS_PROJECT_ID ? { projectId: process.env.EAS_PROJECT_ID } : {} },
});

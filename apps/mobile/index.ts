// Entry: router Expo + handler widget Android (headless JS, dijalankan sistem tanpa membuka app).
import 'expo-router/entry';
import { Platform } from 'react-native';

if (Platform.OS === 'android') {
  const { registerWidgetTaskHandler } = require('react-native-android-widget') as typeof import('react-native-android-widget');
  registerWidgetTaskHandler(require('./src/widget').widgetTaskHandler);
}

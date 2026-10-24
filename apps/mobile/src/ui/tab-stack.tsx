import { Stack } from 'expo-router';
import { useStackOptions } from './nav';

export function TabStack() {
  return <Stack screenOptions={useStackOptions()} />;
}

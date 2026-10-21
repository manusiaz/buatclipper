// Expo web (uji lokal): push native tidak ada — PWA memakai web push (apps/clipper).
export type PushState = 'on' | 'off' | 'denied' | 'unavailable';
export const setupCategories = async (_: { wallet: string; clipAgain: string }) => {};
export const pushState = async (): Promise<PushState> => 'unavailable';
export const enablePush = async (): Promise<PushState> => 'unavailable';
export const disablePush = async (): Promise<PushState> => 'off';
export const targetOf = (_: unknown): string | null => null;
export const Notifications = { addNotificationResponseReceivedListener: (_: (r: never) => void) => ({ remove() {} }), getLastNotificationResponseAsync: async () => null };

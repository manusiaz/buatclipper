// Permukaan di luar app (DS: Lock Screen, Dynamic Island, widget): saat login dan tiap app kembali aktif, segarkan
// widget layar utama dan tautkan token Live Activity iOS. Tidak merender apa pun.
import { useEffect } from 'react';
import { AppState } from 'react-native';
import { useAuth } from './auth';
import { syncLiveActivities } from './live-activity';
import { refreshWidgets } from './widget';

export function DeviceSync() {
  const { claims } = useAuth();
  const uid = claims?.sub;
  useEffect(() => {
    if (!uid) return;
    let stop: (() => void) | undefined;
    const run = () => {
      void refreshWidgets();
      void syncLiveActivities(uid)
        .then((s) => (stop?.(), (stop = s)))
        .catch(() => {});
    };
    run();
    // Aktif lagi → segarkan; ke latar → poll Live Activity berhenti (tak ada JS yang jalan di latar).
    const sub = AppState.addEventListener('change', (s) => (s === 'active' ? run() : (stop?.(), (stop = undefined))));
    return () => (sub.remove(), stop?.());
  }, [uid]);
  return null;
}

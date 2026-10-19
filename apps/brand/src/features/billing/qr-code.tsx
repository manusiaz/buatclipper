import QRCode from 'qrcode';

/** QR sebagai SVG (server): modul gelap → satu path; latar putih tetap (dark mode tidak membalik QR). */
export function QrCode({ value, label, size = 240 }: { value: string; label: string; size?: number }) {
  const { modules } = QRCode.create(value, { errorCorrectionLevel: 'M' });
  const n = modules.size;
  const q = 4;
  let d = '';
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (modules.data[r * n + c]) d += `M${c + q} ${r + q}h1v1h-1z`;
  return (
    <svg
      role="img"
      aria-label={label}
      viewBox={`0 0 ${n + q * 2} ${n + q * 2}`}
      width={size}
      height={size}
      shapeRendering="crispEdges"
      className="h-auto max-w-full rounded-card-sm bg-white text-navy"
    >
      <path d={d} fill="currentColor" />
    </svg>
  );
}

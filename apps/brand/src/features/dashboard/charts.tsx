'use client';

import { useLocale } from 'next-intl';
import { Bar, BarChart, CartesianGrid, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { formatCompact, formatDate, formatNumber } from '@clipper/ui';

const AXIS = { fontSize: 12, fill: 'var(--color-muted)' };
const TOOLTIP = {
  contentStyle: {
    background: 'var(--color-surface)',
    border: '1px solid var(--color-border)',
    borderRadius: 12,
    color: 'var(--color-ink)',
    fontSize: 13,
  },
  labelStyle: { color: 'var(--color-muted)', fontWeight: 600 },
  itemStyle: { color: 'var(--color-ink)' },
};

function DataTable({ caption, head, rows }: { caption: string; head: [string, string]; rows: [string, string][] }) {
  return (
    <table className="sr-only">
      <caption>{caption}</caption>
      <thead>
        <tr><th scope="col">{head[0]}</th><th scope="col">{head[1]}</th></tr>
      </thead>
      <tbody>
        {rows.map(([a, b]) => (
          <tr key={a}><th scope="row">{a}</th><td>{b}</td></tr>
        ))}
      </tbody>
    </table>
  );
}

/** Split views valid per platform: satu seri → satu warna, identitas dari label sumbu. */
export function PlatformChart({ data, caption, labels }: { data: { platform: string; views: number }[]; caption: string; labels: { platform: string; views: string } }) {
  const loc = useLocale() === 'en' ? 'en' : 'id';
  return (
    <figure className="m-0">
      <div aria-hidden className="h-[220px] w-full">
        <ResponsiveContainer>
          <BarChart data={data} layout="vertical" margin={{ top: 4, right: 16, bottom: 4, left: 4 }} barCategoryGap={10}>
            <CartesianGrid horizontal={false} stroke="var(--color-border)" />
            <XAxis type="number" tick={AXIS} tickLine={false} axisLine={false} tickFormatter={(v: number) => formatCompact(v, loc)} />
            <YAxis type="category" dataKey="platform" tick={AXIS} tickLine={false} axisLine={false} width={88} />
            <Tooltip {...TOOLTIP} cursor={{ fill: 'var(--color-subtle)' }} formatter={(v) => [formatNumber(Number(v), loc), labels.views]} />
            <Bar dataKey="views" fill="var(--color-primary)" radius={[0, 4, 4, 0]} maxBarSize={22} />
          </BarChart>
        </ResponsiveContainer>
      </div>
      <DataTable caption={caption} head={[labels.platform, labels.views]} rows={data.map((d) => [d.platform, formatNumber(d.views, loc)])} />
    </figure>
  );
}

/** Kurva views harian (WIB). */
export function DailyChart({ data, caption, labels }: { data: { day: string; views: number }[]; caption: string; labels: { day: string; views: string } }) {
  const loc = useLocale() === 'en' ? 'en' : 'id';
  const day = (d: string) => formatDate(`${d}T00:00:00+07:00`, loc);
  return (
    <figure className="m-0">
      <div aria-hidden className="h-[240px] w-full">
        <ResponsiveContainer>
          <LineChart data={data} margin={{ top: 8, right: 16, bottom: 4, left: 4 }}>
            <CartesianGrid vertical={false} stroke="var(--color-border)" />
            <XAxis dataKey="day" tick={AXIS} tickLine={false} axisLine={false} tickFormatter={day} minTickGap={24} />
            <YAxis tick={AXIS} tickLine={false} axisLine={false} width={48} tickFormatter={(v: number) => formatCompact(v, loc)} />
            <Tooltip
              {...TOOLTIP}
              cursor={{ stroke: 'var(--color-border-strong)' }}
              labelFormatter={(d) => day(String(d))}
              formatter={(v) => [formatNumber(Number(v), loc), labels.views]}
            />
            <Line
              type="monotone"
              dataKey="views"
              stroke="var(--color-primary)"
              strokeWidth={2}
              dot={data.length <= 14 ? { r: 3, fill: 'var(--color-primary)', strokeWidth: 0 } : false}
              activeDot={{ r: 5, stroke: 'var(--color-surface)', strokeWidth: 2 }}
            />
          </LineChart>
        </ResponsiveContainer>
      </div>
      <DataTable caption={caption} head={[labels.day, labels.views]} rows={data.map((d) => [day(d.day), formatNumber(d.views, loc)])} />
    </figure>
  );
}

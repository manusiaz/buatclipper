'use client';

import { Toaster as SonnerToaster, toast, type ToasterProps as SonnerToasterProps } from 'sonner';
import { Icon } from './icon';
import { Spinner } from './spinner';

export { toast };

export interface ToasterProps extends Partial<Pick<SonnerToasterProps, 'position' | 'offset' | 'mobileOffset' | 'visibleToasts' | 'duration' | 'closeButton' | 'dir'>> {}

/**
 * DS 12 toast: ink pill, white text, coloured icon, blue action ("Urungkan"). One visible at a time,
 * 5 s, bottom-center (above the mobile bottom nav via `mobileOffset`). Mount once in the root layout.
 * Usage: toast.success('Kode referral disalin'), toast('Clip dihapus', { action: { label: 'Urungkan', onClick } }).
 */
export function Toaster({
  position = 'bottom-center',
  visibleToasts = 1,
  duration = 5000,
  offset = 24,
  mobileOffset = { bottom: 'calc(84px + env(safe-area-inset-bottom, 0px))', left: 16, right: 16 },
  closeButton = false,
  ...rest
}: ToasterProps) {
  return (
    <SonnerToaster
      position={position}
      visibleToasts={visibleToasts}
      duration={duration}
      offset={offset}
      mobileOffset={mobileOffset}
      closeButton={closeButton}
      gap={8}
      icons={{
        success: <Icon name="check_circle" size={20} filled className="text-[#7ED3A6]" />,
        error: <Icon name="error" size={20} filled className="text-[#FF9C9C]" />,
        warning: <Icon name="warning" size={20} filled className="text-[#FFC266]" />,
        info: <Icon name="info" size={20} filled className="text-[#A9C1FF]" />,
        loading: <Spinner size={18} className="text-white/80" />,
        close: <Icon name="close" size={16} />,
      }}
      toastOptions={{
        unstyled: true,
        classNames: {
          toast:
            'group/toast pointer-events-auto flex w-full items-center gap-3 rounded-card-sm bg-navy px-4 py-3 text-sm font-semibold text-white shadow-[0_16px_32px_-12px_rgb(10_18_38/0.6)] sm:w-[380px] dark:bg-[#1a2545] dark:ring-1 dark:ring-white/10',
          content: 'flex min-w-0 flex-1 flex-col gap-0.5',
          title: 'leading-5',
          description: 'text-caption font-medium text-white/70',
          icon: 'shrink-0 [&>svg]:block',
          actionButton:
            'shrink-0 rounded-chip px-2.5 py-1.5 text-sm font-bold text-[#7FA2FF] transition-colors hover:bg-white/10 focus-ring',
          cancelButton: 'shrink-0 rounded-chip px-2.5 py-1.5 text-sm font-semibold text-white/70 hover:bg-white/10',
          closeButton:
            'absolute -top-2 -right-2 grid size-6 place-items-center rounded-full bg-navy-2 text-white ring-2 ring-canvas hover:bg-navy-3',
          error: 'bg-[#2A0F14] dark:bg-[#2A0F14]',
        },
      }}
      {...rest}
    />
  );
}

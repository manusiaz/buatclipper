import type { Locale, Translate } from '../i18n';
import type { AssetDraft, BuilderContext, CampaignDraft, StepId, UploadKind } from '../types';

export interface StepProps {
  draft: CampaignDraft;
  update: (fn: (d: CampaignDraft) => CampaignDraft) => void;
  ctx: BuilderContext;
  /** Brief frozen since submission: everything read-only except FAQ. */
  locked: boolean;
  t: Translate;
  locale: Locale;
  /** Translated message for a field path (prefix = also match child paths, e.g. "required_hashtags.2"). */
  errorOf: (field: string, prefix?: boolean) => string | undefined;
  /** Validates, saves the draft first when it has no id, uploads to the signed URL; null on failure (message shown). */
  upload: (kind: UploadKind, file: File) => Promise<AssetDraft | null>;
  uploading: Partial<Record<UploadKind, boolean>>;
  goTo: (step: StepId) => void;
}

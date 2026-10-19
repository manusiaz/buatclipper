'use client';

import { useCallback, useEffect, useMemo, useRef, useState, type JSX } from 'react';
import { Alert, Badge, Button, Card, ConfirmDialog, Icon, Spinner, Stepper, cn, formatDateTime, toast } from '@clipper/ui';
import { STEPS } from './constants';
import { costSummary } from './cost';
import { mapServerError, type MappedServerError } from './errors';
import { idr, useBuilderT, useUiLocale } from './i18n';
import { baseRules, isEditable, newDraft, newKey } from './model';
import { toSavePayload } from './payload';
import { isPoolOrRuleIssue, schemaIssues, submitIssues, type DraftIssue } from './schema';
import { BasicsStep } from './steps/basics';
import { BriefStep } from './steps/brief';
import { BudgetStep } from './steps/budget';
import { EligibilityStep } from './steps/eligibility';
import { PlatformsStep } from './steps/platforms';
import { RewardsStep } from './steps/rewards';
import { ScheduleStep } from './steps/schedule';
import type { StepProps } from './steps/shared';
import { SummaryStep } from './steps/summary';
import type { AssetDraft, BuilderContext, CampaignBuilderProps, CampaignDraft, SaveResult, StepId, UploadKind } from './types';
import { assetKindForMime, checkFile, formatBytes, putToSignedUrl } from './upload';

const AUTOSAVE_MS = 2500;
type SaveReason = 'auto' | 'manual' | 'upload' | 'submit';
type SaveState = { status: 'idle' | 'saving' | 'saved' | 'error'; at?: number; partial?: boolean };

const SUMMARY = STEPS.length;

/** Issues that stop a save: column issues (pool/rule issues only hold back pools + rules); locked drafts send only faq. */
function blockingIssues(d: CampaignDraft, issues: DraftIssue[] = schemaIssues(d)): DraftIssue[] {
  return isEditable(d) ? issues.filter((i) => !isPoolOrRuleIssue(i)) : issues.filter((i) => i.field === 'faq' || i.field.startsWith('faq.'));
}

/** Base-rate rules (step 3) are edited on the platforms step too: their issues count for both steps. */
function issueSteps(issue: DraftIssue, baseRuleIdx: ReadonlySet<number>): StepId[] {
  const m = /^rules\.(\d+)/.exec(issue.field);
  if (m && baseRuleIdx.has(Number(m[1]))) return ['platforms', 'rewards'];
  return [issue.step];
}

function fallbackFee(ctx: BuilderContext): BuilderContext['fee'] {
  const rule = ctx.feeRules?.find((r) => r.scope === 'org') ?? ctx.feeRules?.find((r) => r.scope === 'global');
  return rule ? { mgmt_fee_pct: rule.mgmt_fee_pct, admin_fee_pct: rule.admin_fee_pct } : ctx.fee;
}

/**
 * 7-step campaign builder (F-B02) shared by brand.{domain}/[org]/campaigns/new and admin.{domain}/campaigns/new (F-A03).
 * Draft is saved through actions.save (api.save_campaign) — autosave while editing, first save creates the campaign
 * (storage paths need its id), "Ajukan" / "Kirim ke brand" saves with submit = true.
 */
export function CampaignBuilder({ context, initial, actions, onSaved, sidePanel }: CampaignBuilderProps): JSX.Element {
  const t = useBuilderT();
  const locale = useUiLocale();

  const [draft, setDraft] = useState<CampaignDraft>(() => initial ?? newDraft(context));
  const draftRef = useRef(draft);
  const versionRef = useRef(0);
  const savedVersionRef = useRef(0);
  const [version, setVersion] = useState(0);
  const [savedVersion, setSavedVersion] = useState(0);
  const [stepIndex, setStepIndex] = useState(() => (initial && !isEditable(initial) ? SUMMARY : 0));
  const [attempted, setAttempted] = useState<ReadonlySet<StepId>>(() => new Set());
  const [reachedSummary, setReachedSummary] = useState(() => !!initial && !isEditable(initial));
  const [saveState, setSaveState] = useState<SaveState>({ status: initial?.id ? 'saved' : 'idle' });
  const [serverError, setServerError] = useState<MappedServerError | null>(null);
  const [effectiveFee, setEffectiveFee] = useState(context.fee);
  const [uploading, setUploading] = useState<Partial<Record<UploadKind, boolean>>>({});
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [sideOpen, setSideOpen] = useState(false);

  const props = useRef({ actions, onSaved, context });
  useEffect(() => {
    props.current = { actions, onSaved, context };
  }, [actions, onSaved, context]);
  const queue = useRef<Promise<unknown>>(Promise.resolve());
  const topRef = useRef<HTMLDivElement>(null);
  const headingRef = useRef<HTMLHeadingElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);

  const locked = !isEditable(draft);
  const isSummary = stepIndex >= SUMMARY;
  const currentStep: StepId = isSummary ? 'summary' : STEPS[stepIndex]!;
  const dirty = version !== savedVersion;
  const suspended = context.org.status === 'suspended';

  /* ───────────── draft mutations ───────────── */

  const update = useCallback((fn: (d: CampaignDraft) => CampaignDraft) => {
    const next = fn(draftRef.current);
    if (next === draftRef.current) return;
    draftRef.current = next;
    versionRef.current += 1;
    setDraft(next);
    setVersion(versionRef.current);
    setServerError((e) => (e && e.field ? null : e));
  }, []);

  const patchSilently = useCallback((fn: (d: CampaignDraft) => CampaignDraft) => {
    draftRef.current = fn(draftRef.current);
    setDraft(draftRef.current);
  }, []);

  /* ───────────── validation ───────────── */

  const schemaIss = useMemo(() => schemaIssues(draft), [draft]);
  const submitIss = useMemo(() => submitIssues(draft), [draft]);
  const blocking = useMemo(() => blockingIssues(draft, schemaIss), [draft, schemaIss]);
  const baseIdx = useMemo(() => {
    const keys = new Set(baseRules(draft).map((r) => r.key));
    return new Set(draft.rules.map((r, i) => (keys.has(r.key) ? i : -1)).filter((i) => i >= 0));
  }, [draft]);

  const stepIssues = useCallback(
    (step: StepId, withSubmit: boolean) =>
      [...schemaIss, ...(withSubmit ? submitIss : [])].filter((i) => issueSteps(i, baseIdx).includes(step)),
    [schemaIss, submitIss, baseIdx],
  );

  const visible = useMemo(() => {
    const shown = schemaIss.filter((i) => issueSteps(i, baseIdx).some((s) => attempted.has(s)));
    return reachedSummary ? [...shown, ...submitIss] : shown;
  }, [schemaIss, submitIss, attempted, reachedSummary, baseIdx]);

  const errorOf = useCallback(
    (field: string, prefix = false): string | undefined => {
      const match = (f: string | null) => f != null && (f === field || (prefix && f.startsWith(`${field}.`)));
      if (serverError?.field && match(serverError.field)) return t(serverError.message);
      const issue = visible.find((i) => match(i.field));
      return issue ? t(issue.message) : undefined;
    },
    [serverError, visible, t],
  );

  /* ───────────── saving ───────────── */

  const runSave = useCallback(
    (submit: boolean, reason: SaveReason): Promise<SaveResult | null> => {
      const job = queue.current.then(async (): Promise<SaveResult | null> => {
        const { actions: act, onSaved: saved, context: ctx } = props.current;
        const d = draftRef.current;
        const v = versionRef.current;
        if (!submit && d.id && v === savedVersionRef.current) return { ok: true, id: d.id };
        const all = schemaIssues(d);
        const block = submit ? all : blockingIssues(d, all);
        if (block.length > 0) {
          if (reason !== 'auto') setAttempted((prev) => new Set([...prev, ...block.map((i) => i.step)]));
          return null;
        }
        const payload = toSavePayload(d);
        const partial = isEditable(d) && !('pools' in payload);
        setSaveState((s) => ({ ...s, status: 'saving' }));
        let res: SaveResult;
        try {
          res = await act.save(payload, submit);
        } catch {
          res = { ok: false, error: 'network' };
        }
        if (!res.ok) {
          const mapped = mapServerError(res.error, res.detail);
          setServerError(mapped);
          setSaveState({ status: 'error' });
          if (reason !== 'auto' && mapped.step && mapped.step !== 'summary') setAttempted((prev) => new Set([...prev, mapped.step!]));
          return res;
        }
        const id = res.id;
        const sendsToBrand = ctx.mode === 'admin' && d.service_mode === 'managed';
        patchSilently((cur) => {
          const next: CampaignDraft = { ...cur, id };
          if (cur.status === 'rejected') next.status = 'draft';
          if (submit && !sendsToBrand) next.status = 'in_review';
          if (cur.fee === d.fee && d.fee.mode !== 'keep') next.fee = { mode: 'keep' };
          return next;
        });
        if (d.fee.mode === 'set') setEffectiveFee({ mgmt_fee_pct: d.fee.mgmt_fee_pct, admin_fee_pct: d.fee.admin_fee_pct });
        else if (d.fee.mode === 'clear') setEffectiveFee(fallbackFee(ctx));
        savedVersionRef.current = v;
        setSavedVersion(v);
        setSaveState({ status: 'saved', at: Date.now(), partial });
        setServerError(null);
        saved?.(id, submit);
        return res;
      });
      queue.current = job.catch(() => null);
      return job;
    },
    [patchSilently],
  );

  const canAutosave = dirty && blocking.length === 0 && !suspended;
  useEffect(() => {
    if (!canAutosave) return;
    const timer = setTimeout(() => void runSave(false, 'auto'), AUTOSAVE_MS);
    return () => clearTimeout(timer);
  }, [version, canAutosave, runSave]);

  /* ───────────── unsaved-changes guard ───────────── */

  const dirtyRef = useRef(dirty);
  useEffect(() => {
    dirtyRef.current = dirty;
  }, [dirty]);
  useEffect(() => {
    const onBeforeUnload = (e: BeforeUnloadEvent) => {
      if (!dirtyRef.current) return;
      e.preventDefault();
      e.returnValue = '';
    };
    // In-app navigation (next/link) does not fire beforeunload: intercept same-tab link clicks while dirty.
    const onClick = (e: MouseEvent) => {
      if (!dirtyRef.current || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const a = (e.target as Element | null)?.closest?.('a[href]') as HTMLAnchorElement | null;
      if (!a || a.target === '_blank' || a.hasAttribute('download')) return;
      const url = new URL(a.href, window.location.href);
      if (url.origin === window.location.origin && url.pathname === window.location.pathname && url.search === window.location.search) return;
      if (!window.confirm(t('guard.leave'))) {
        e.preventDefault();
        e.stopPropagation();
      }
    };
    window.addEventListener('beforeunload', onBeforeUnload);
    document.addEventListener('click', onClick, true);
    return () => {
      window.removeEventListener('beforeunload', onBeforeUnload);
      document.removeEventListener('click', onClick, true);
    };
  }, [t]);

  /* ───────────── uploads ───────────── */

  const upload = useCallback(
    async (kind: UploadKind, file: File): Promise<AssetDraft | null> => {
      const check = checkFile(kind, file);
      if (!check.ok) {
        toast.error(check.reason === 'too_big' ? t('upload.tooBig', { max: formatBytes(check.maxBytes, locale) }) : t('upload.badType'));
        return null;
      }
      setUploading((u) => ({ ...u, [kind]: true }));
      try {
        let id = draftRef.current.id;
        if (!id) {
          const r = await runSave(false, 'upload');
          id = r && r.ok ? r.id : null;
        }
        if (!id) {
          toast.error(t('upload.needSave'));
          return null;
        }
        const signed = await props.current.actions.uploadUrl({ campaignId: id, kind, filename: file.name, contentType: check.contentType, size: file.size });
        if (!signed.ok) {
          toast.error(t('upload.failed'));
          return null;
        }
        const put = await putToSignedUrl(signed.signedUrl, file, check.contentType);
        if (!put.ok) {
          toast.error(t('upload.failed'));
          return null;
        }
        toast.success(t('upload.done', { name: file.name }));
        return {
          key: newKey('asset'),
          id: null,
          kind: kind === 'cover' ? 'cover' : assetKindForMime(check.contentType),
          audience: kind === 'internal' ? 'internal' : 'clipper',
          storage_path: signed.path,
          url: null,
          size_bytes: file.size,
          name: file.name,
        };
      } catch {
        toast.error(t('upload.failed'));
        return null;
      } finally {
        setUploading((u) => ({ ...u, [kind]: false }));
      }
    },
    [runSave, t, locale],
  );

  /* ───────────── navigation ───────────── */

  const goToIndex = useCallback((i: number) => {
    setStepIndex(i);
    if (i >= SUMMARY) setReachedSummary(true);
    requestAnimationFrame(() => {
      topRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
      headingRef.current?.focus({ preventScroll: true });
    });
  }, []);
  const goTo = useCallback((step: StepId) => goToIndex(step === 'summary' ? SUMMARY : STEPS.indexOf(step as (typeof STEPS)[number])), [goToIndex]);

  const focusFirstInvalid = () =>
    requestAnimationFrame(() => {
      const el = contentRef.current?.querySelector<HTMLElement>('[aria-invalid="true"], [role="alert"]');
      el?.focus?.();
      el?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    });

  const next = () => {
    if (!locked && stepIssues(currentStep, false).length > 0) {
      setAttempted((prev) => new Set([...prev, currentStep]));
      focusFirstInvalid();
      return;
    }
    if (dirty && blocking.length === 0 && !suspended) void runSave(false, 'auto');
    goToIndex(stepIndex + 1);
  };

  const saveNow = async () => {
    const r = await runSave(false, 'manual');
    if (r === null) {
      toast.error(t('save.invalidToast'));
      const first = blockingIssues(draftRef.current)[0];
      if (first && first.step !== currentStep) goTo(first.step);
      else focusFirstInvalid();
    } else if (r.ok) toast.success(t('save.savedToast'));
    else toast.error(t(mapServerError(r.error, r.detail).message));
  };

  /* ───────────── submit ───────────── */

  const sendsToBrand = context.mode === 'admin' && draft.service_mode === 'managed';
  const disabledReason = suspended
    ? t('summary.suspended')
    : draft.is_template
      ? t('summary.template')
      : !sendsToBrand && context.org.status !== 'verified'
        ? t('summary.unverified')
        : null;

  const trySubmit = () => {
    const issues = [...schemaIssues(draftRef.current), ...submitIssues(draftRef.current)];
    if (issues.length > 0) {
      setAttempted((prev) => new Set([...prev, ...issues.map((i) => i.step)]));
      const first = issues[0]!;
      if (first.step !== 'summary') goTo(first.step);
      toast.error(t('summary.notReady'));
      return;
    }
    setConfirmOpen(true);
  };

  const confirmSubmit = async () => {
    const r = await runSave(true, 'submit');
    if (r?.ok) toast.success(sendsToBrand ? t('summary.sent') : t('summary.submitted'));
    else if (r && !r.ok) {
      const m = mapServerError(r.error, r.detail);
      if (m.step && m.step !== 'summary') goTo(m.step);
    }
  };

  /* ───────────── render ───────────── */

  const cost = useMemo(() => costSummary(draft, { ...context, fee: effectiveFee }), [draft, context, effectiveFee]);

  const stepProps: StepProps = { draft, update, ctx: context, locked, t, locale, errorOf, upload, uploading, goTo };

  const saveLabel = (() => {
    if (saveState.status === 'saving') return t('save.saving');
    if (dirty && blocking.length > 0) return !draft.id && blocking.some((i) => i.field === 'title') ? t('save.needTitle') : t('save.invalid');
    if (dirty) return t('save.dirty');
    if (saveState.status === 'error') return t('save.error');
    if (saveState.status === 'saved') {
      if (saveState.partial) return t('save.partial');
      return saveState.at ? t('save.saved', { time: formatDateTime(saveState.at, locale, { timeStyle: 'short' }) }) : t('save.upToDate');
    }
    return t('save.idle');
  })();
  const saveTone =
    saveState.status === 'error' || (dirty && blocking.length > 0) ? 'text-danger-fg' : saveState.partial && !dirty ? 'text-warn-fg' : 'text-muted';

  const steps = STEPS.map((id) => ({
    label: t(`steps.${id}`),
    error: !locked && attempted.has(id) && stepIssues(id, reachedSummary).length > 0,
  }));

  const submitArea = locked ? null : (
    <Card variant="outline" padding="md" as="section" className="flex flex-col gap-3">
      <div className="flex flex-col gap-1">
        <h3 className="text-h6">{sendsToBrand ? t('summary.sendHeading') : t('summary.submitHeading')}</h3>
        <p className="text-body-s text-muted">{sendsToBrand ? t('summary.sendHint') : t('summary.submitHint')}</p>
        {!sendsToBrand && context.mode === 'brand' && draft.service_mode === 'managed' ? (
          <p className="text-body-s text-text-2">{t('summary.managedWaitHint')}</p>
        ) : null}
      </div>
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
        <Button size="lg" iconLeft={sendsToBrand ? 'send' : 'task'} disabled={!!disabledReason} aria-describedby={disabledReason ? 'cb-submit-reason' : undefined} onClick={trySubmit}>
          {sendsToBrand ? t('actions.sendToBrand') : t('actions.submit')}
        </Button>
        {disabledReason ? (
          <p id="cb-submit-reason" className="flex items-start gap-1.5 text-body-s text-warn-fg">
            <Icon name="lock" size={16} className="mt-0.5" />
            {disabledReason}
          </p>
        ) : null}
      </div>
    </Card>
  );

  let body: JSX.Element;
  switch (currentStep) {
    case 'basics':
      body = <BasicsStep {...stepProps} />;
      break;
    case 'brief':
      body = <BriefStep {...stepProps} />;
      break;
    case 'platforms':
      body = <PlatformsStep {...stepProps} />;
      break;
    case 'rewards':
      body = <RewardsStep {...stepProps} />;
      break;
    case 'budget':
      body = <BudgetStep {...stepProps} />;
      break;
    case 'eligibility':
      body = <EligibilityStep {...stepProps} />;
      break;
    case 'schedule':
      body = <ScheduleStep {...stepProps} />;
      break;
    default:
      body = <SummaryStep {...stepProps} cost={cost} issues={schemaIss.concat(submitIss)} effectiveFee={effectiveFee} submit={submitArea} />;
  }

  const heading = draft.title.trim() || (context.mode === 'admin' ? t('heading.admin') : draft.id ? t('heading.edit') : t('heading.new'));
  const hasSide = context.mode === 'admin' && sidePanel != null;

  return (
    <div ref={topRef} className={cn('flex w-full min-w-0 scroll-mt-4 flex-col gap-6', hasSide && 'lg:flex-row lg:items-start')}>
      <div className="flex min-w-0 flex-1 flex-col gap-5">
        <header className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div className="flex min-w-0 flex-col gap-1.5">
            <div className="flex flex-wrap items-center gap-2">
              {context.mode === 'admin' ? (
                <Badge tone="premium" icon="admin_panel_settings" size="sm">
                  {t('heading.adminBadge')}
                </Badge>
              ) : null}
              {draft.service_mode === 'managed' ? (
                <Badge tone="primary" icon="support_agent" size="sm">
                  {t('brief.modeManaged')}
                </Badge>
              ) : null}
              <Badge tone="neutral" size="sm">
                {t(`status.${draft.status}`)}
              </Badge>
              <span className="truncate text-caption text-muted">{context.org.name}</span>
            </div>
            <h1 className="truncate text-h3">{heading}</h1>
            <p className={cn('flex items-center gap-1.5 text-caption font-medium', saveTone)} role="status" aria-live="polite">
              {saveState.status === 'saving' ? <Spinner size={12} /> : <Icon name={dirty ? 'edit' : 'check_circle'} size={14} />}
              {saveLabel}
            </p>
          </div>
          <div className="flex shrink-0 flex-wrap gap-2">
            {hasSide ? (
              <Button variant="secondary" iconLeft="description" className="lg:hidden" aria-expanded={sideOpen} aria-controls="cb-side" onClick={() => setSideOpen((o) => !o)}>
                {sideOpen ? t('nav.sidePanelHide') : t('nav.sidePanelShow')}
              </Button>
            ) : null}
            <Button variant="secondary" iconLeft="bookmark" loading={saveState.status === 'saving'} disabled={suspended || (!dirty && !!draft.id)} onClick={() => void saveNow()}>
              {t('actions.saveDraft')}
            </Button>
          </div>
        </header>

        {suspended ? (
          <Alert tone="danger" variant="banner" title={t('banner.suspendedTitle')}>
            {t('banner.suspendedBody')}
          </Alert>
        ) : null}
        {locked ? (
          <Alert tone="info" variant="banner" icon="lock" title={t('banner.lockedTitle')} action={currentStep !== 'brief' ? { label: t('banner.lockedAction'), onClick: () => goTo('brief') } : undefined}>
            {t('banner.lockedBody')}
          </Alert>
        ) : null}
        {draft.status === 'rejected' ? (
          <Alert tone="warn" variant="banner" title={t('banner.rejectedTitle')}>
            {t('banner.rejectedBody')}
          </Alert>
        ) : null}
        {!locked && !suspended && context.org.status === 'pending_verification' && context.mode === 'brand' ? (
          <Alert tone="warn" variant="banner" title={t('banner.unverifiedTitle')}>
            {t('banner.unverifiedBody')}
          </Alert>
        ) : null}
        {draft.is_template ? (
          <Alert tone="info" variant="banner" title={t('banner.templateTitle')}>
            {t('banner.templateBody')}
          </Alert>
        ) : null}

        <Stepper
          steps={steps}
          current={stepIndex}
          onStepClick={(i) => goToIndex(i)}
          label={t('nav.stepperLabel')}
          progressLabel={(n, total) => (isSummary ? t('nav.summaryProgress', { total }) : t('nav.progress', { n, total }))}
        />

        <Card variant="default" padding="lg" as="section" aria-labelledby="cb-step-heading" className="flex flex-col gap-6">
          <div className="flex flex-col gap-1">
            <p className="text-overline text-muted uppercase">{isSummary ? t('nav.finalStep') : t('nav.stepOf', { n: stepIndex + 1, total: STEPS.length })}</p>
            <h2 id="cb-step-heading" ref={headingRef} tabIndex={-1} className="text-h4 outline-none">
              {t(`steps.${currentStep}`)}
            </h2>
          </div>

          {serverError ? (
            <Alert
              tone="danger"
              title={t(serverError.message)}
              action={serverError.step && serverError.step !== currentStep ? { label: t('server.openStep', { step: t(`steps.${serverError.step}`) }), onClick: () => goTo(serverError.step!) } : undefined}
              onDismiss={() => setServerError(null)}
              dismissLabel={t('common.close')}
            >
              {serverError.message === 'server.generic' && serverError.detail ? serverError.detail : null}
            </Alert>
          ) : null}

          <div ref={contentRef} className="flex min-w-0 flex-col gap-6">
            {body}
          </div>
        </Card>

        <nav
          aria-label={t('nav.stepNav')}
          className="sticky bottom-0 z-10 flex items-center justify-between gap-3 rounded-card-sm border border-border bg-surface/95 p-3 pb-[max(0.75rem,var(--safe-bottom))] shadow-bar backdrop-blur sm:static sm:border-0 sm:bg-transparent sm:p-0 sm:shadow-none sm:backdrop-blur-none"
        >
          {stepIndex > 0 ? (
            <Button variant="secondary" iconLeft="arrow_back" onClick={() => goToIndex(stepIndex - 1)}>
              {t('nav.back')}
            </Button>
          ) : (
            <span />
          )}
          {!isSummary ? (
            <Button iconRight="arrow_forward" onClick={next}>
              {stepIndex === SUMMARY - 1 ? t('nav.toSummary') : t('nav.next')}
            </Button>
          ) : null}
        </nav>
      </div>

      {hasSide ? (
        <aside
          id="cb-side"
          aria-label={t('nav.sidePanelTitle')}
          className={cn('min-w-0 shrink-0 flex-col gap-3 lg:sticky lg:top-4 lg:flex lg:w-[min(380px,34%)]', sideOpen ? 'flex' : 'hidden')}
        >
          <Card variant="outline" padding="md" className="flex max-h-[calc(100dvh-2rem)] flex-col gap-3 overflow-y-auto">
            <h2 className="flex items-center gap-2 text-h6">
              <Icon name="description" size={20} />
              {t('nav.sidePanelTitle')}
            </h2>
            {sidePanel}
          </Card>
        </aside>
      ) : null}

      <ConfirmDialog
        open={confirmOpen}
        onOpenChange={setConfirmOpen}
        tone="primary"
        icon={sendsToBrand ? 'send' : 'task'}
        title={sendsToBrand ? t('summary.sendTitle') : t('summary.submitTitle')}
        description={sendsToBrand ? t('summary.sendBody') : t('summary.submitBody', { total: idr(cost.total, locale) })}
        confirmLabel={sendsToBrand ? t('actions.sendToBrand') : t('actions.submit')}
        cancelLabel={t('common.cancel')}
        onConfirm={confirmSubmit}
      />
    </div>
  );
}


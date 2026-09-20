"use client";

/** Piezas compartidas entre AdminOpsPanel y AdminHomeReport. */

import type { AdminClaim } from "@/hooks/useAdminClaims";

export function Spinner() {
  return (
    <div className="flex min-h-[30vh] items-center justify-center">
      <div className="h-9 w-9 animate-spin rounded-full border-2 border-brand-border border-t-brand-green" />
    </div>
  );
}

export function EmptyBox({ icon, text }: { icon: string; text: string }) {
  return (
    <div className="rounded-2xl border border-brand-border bg-brand-card py-10 text-center">
      <p className="text-3xl">{icon}</p>
      <p className="mt-2 text-sm text-brand-muted">{text}</p>
    </div>
  );
}

export const BTN_COLOR: Record<string, string> = {
  green:  "border-brand-green text-brand-green",
  orange: "border-orange-400 text-orange-400",
  red:    "border-red-400 text-red-400",
  muted:  "border-brand-border text-brand-muted",
};

export function ActionBtn({ label, color, onClick, disabled, busy }: {
  label: string; color: keyof typeof BTN_COLOR; onClick: () => void; disabled?: boolean; busy?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled || busy}
      className={`rounded-lg border px-3 py-1.5 text-xs font-medium transition-opacity disabled:opacity-40 ${BTN_COLOR[color]}`}
    >
      {busy ? "…" : label}
    </button>
  );
}

export function ClaimBadge({ claim, busy, onClaim, onRelease }: {
  claim?: AdminClaim; busy?: boolean; onClaim: () => void; onRelease: () => void;
}) {
  if (claim && !claim.is_mine) {
    return (
      <span className="inline-block w-fit rounded-lg border border-red-400/30 bg-red-400/10 px-2.5 py-1 text-xs font-medium text-red-400">
        🔒 En trabajo por {claim.claimed_by_name ?? "otro admin"}
      </span>
    );
  }
  if (claim?.is_mine) {
    return (
      <button onClick={onRelease} disabled={busy}
        className="w-fit rounded-lg border border-brand-green bg-brand-green/10 px-2.5 py-1 text-xs font-medium text-brand-green">
        👤 Lo atiendes tú · liberar
      </button>
    );
  }
  return (
    <button onClick={onClaim} disabled={busy}
      className="w-fit rounded-lg border border-brand-border bg-brand-card2 px-2.5 py-1 text-xs font-medium text-brand-muted hover:text-white">
      ✋ Tomar este caso
    </button>
  );
}

export function Row({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  return (
    <div className="flex items-center justify-between border-t border-brand-border pt-2 first:border-0 first:pt-0">
      <span className="text-sm text-brand-muted">{label}</span>
      <span className={`text-sm font-bold ${highlight ? "text-brand-green" : "text-white"}`}>{value}</span>
    </div>
  );
}

export function Section({ title, count, children }: { title: string; count: number; children: React.ReactNode }) {
  return (
    <div>
      <h3 className="mb-3 text-sm font-semibold uppercase tracking-wide text-brand-muted">{title}{count > 0 ? ` · ${count}` : ""}</h3>
      {children}
    </div>
  );
}

export function Modal({ open, onClose, title, children }: {
  open: boolean; onClose: () => void; title: string; children: React.ReactNode;
}) {
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4" onClick={onClose}>
      <div
        onClick={(e) => e.stopPropagation()}
        className="max-h-[85vh] w-full max-w-md overflow-y-auto rounded-2xl border border-brand-border bg-brand-card p-6"
      >
        <h3 className="mb-4 text-lg font-bold text-white">{title}</h3>
        {children}
      </div>
    </div>
  );
}

export const inputCls = "w-full rounded-lg border border-brand-border bg-brand-bg px-3 py-2 text-sm text-white placeholder:text-brand-muted";
export const labelCls = "mb-1 block text-xs font-medium text-brand-muted";

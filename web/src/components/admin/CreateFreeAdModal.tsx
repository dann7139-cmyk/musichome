"use client";

/**
 * Subir un anuncio GRATIS desde la web (petición real: "que yo pueda subir
 * los gratis" — sin Stripe/Conekta de por medio, eso es aparte). Usa
 * create_free_ad(), la MISMA RPC que ya usa la app móvil para esto —
 * ya viene limitada a role='admin' del lado del servidor, así que no hay
 * nada nuevo que asegurar aquí.
 *
 * Fuera de esta pieza (aparte, con precio/paquete/pago): banner_home o
 * profile_ad pagados, y "Grupo Destacado" (sponsored_group) — ese tipo
 * activa una fila en sponsored_groups que create_free_ad no toca.
 */

import { useState } from "react";
import { supabase } from "@/lib/supabase";

const COUNTRIES = ["México", "Estados Unidos", "Canadá"];

// 2026-09-18 — extendido para: (1) editar un anuncio gratis ya publicado
// (pasa `editingAd`, llama update_free_ad en vez de create_free_ad — mismo
// patrón que AdApprovalScreen de la app), y (2) admin_ops con país fijo
// (`lockedCountry` — nunca puede publicar "Internacional" ni el país de
// otro admin, sql/667). Con `editingAd` o `hideTrigger`, no dibuja su
// propio botón — el padre controla cuándo se abre.
interface AdLike {
  id: string; type: string; title: string; subtitle: string | null;
  button_text: string | null; link_url: string | null;
  media_url: string | null; media_type: string | null;
  target_country: string | null; target_state: string | null;
  tag: string | null; starts_at: string | null; ends_at: string | null;
}

export default function CreateFreeAdModal({
  onCreated, editingAd, onClose, lockedCountry, hideTrigger,
}: {
  onCreated: () => void;
  editingAd?: AdLike | null;
  onClose?: () => void;
  lockedCountry?: string;
  hideTrigger?: boolean;
}) {
  const isEdit = !!editingAd;
  const [open, setOpen] = useState(isEdit);
  const [type, setType] = useState<"banner_home" | "profile_ad">((editingAd?.type as any) ?? "banner_home");
  const [title, setTitle] = useState(editingAd?.title ?? "");
  const [subtitle, setSubtitle] = useState(editingAd?.subtitle ?? "");
  const [buttonText, setButtonText] = useState(editingAd?.button_text ?? "");
  const [linkUrl, setLinkUrl] = useState(editingAd?.link_url ?? "");
  const [country, setCountry] = useState(lockedCountry ?? editingAd?.target_country ?? "");
  const [state, setState] = useState(editingAd?.target_state ?? "");
  const [durationDays, setDurationDays] = useState(() => {
    if (editingAd?.starts_at && editingAd?.ends_at) {
      const d = Math.max(1, Math.round((new Date(editingAd.ends_at).getTime() - new Date(editingAd.starts_at).getTime()) / 86400000));
      return String(d);
    }
    return "30";
  });
  const [tag, setTag] = useState(editingAd?.tag ?? "");
  const [file, setFile] = useState<File | null>(null);
  const [existingMediaUrl, setExistingMediaUrl] = useState(editingAd?.media_url ?? null);
  const [existingMediaType, setExistingMediaType] = useState(editingAd?.media_type ?? null);
  const [saving, setSaving] = useState(false);

  const reset = () => {
    setType("banner_home"); setTitle(""); setSubtitle(""); setButtonText("");
    setLinkUrl(""); setCountry(lockedCountry ?? ""); setState(""); setDurationDays("30");
    setTag(""); setFile(null); setExistingMediaUrl(null); setExistingMediaType(null);
  };

  const close = () => {
    setOpen(false);
    if (isEdit) { onClose?.(); } else { reset(); }
  };

  const submit = async () => {
    if (!title.trim()) { window.alert("El título es obligatorio."); return; }
    setSaving(true);
    try {
      let mediaUrl: string | null = existingMediaUrl;
      let mediaType: string | null = existingMediaType;

      if (file) {
        const { data: { user } } = await supabase.auth.getUser();
        if (!user) throw new Error("Sesión no encontrada.");
        const isVideo = file.type.startsWith("video/");
        mediaType = isVideo ? "video" : "image";
        const ext = file.name.split(".").pop() || (isVideo ? "mp4" : "jpg");
        const path = `${user.id}/free_${Date.now()}.${ext}`;
        const { error: upErr } = await supabase.storage
          .from("advertisements")
          .upload(path, file, { contentType: file.type, upsert: true });
        if (upErr) throw new Error("No se pudo subir el archivo: " + upErr.message);
        const { data: pub } = supabase.storage.from("advertisements").getPublicUrl(path);
        mediaUrl = pub.publicUrl;
      }

      const rpcName = isEdit ? "update_free_ad" : "create_free_ad";
      const rpcArgs: Record<string, unknown> = {
        ...(isEdit ? { p_id: editingAd!.id } : {}),
        p_type: type,
        p_title: title.trim(),
        p_subtitle: subtitle.trim() || null,
        p_button_text: buttonText.trim() || null,
        p_media_url: mediaUrl,
        p_media_type: mediaType,
        p_target_state: state.trim() || null,
        // lockedCountry (admin_ops) manda siempre — el servidor de todos
        // modos lo fuerza a su propio país (sql/667), esto es solo para
        // que la UI no muestre un valor distinto al que en realidad quedará.
        p_target_country: lockedCountry ?? (country || null),
        p_duration_days: durationDays ? Number(durationDays) : 30,
        p_tag: tag.trim() || null,
        p_link_url: linkUrl.trim() || null,
      };
      const { data, error } = await supabase.rpc(rpcName, rpcArgs);

      if (error || !(data as any)?.ok) {
        throw new Error((data as any)?.error ?? error?.message ?? "No se pudo guardar el anuncio.");
      }

      window.alert(isEdit ? "Cambios guardados." : "Anuncio publicado y activo.");
      close();
      onCreated();
    } catch (e: any) {
      window.alert(e?.message ?? "No se pudo guardar el anuncio.");
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      {!hideTrigger && !isEdit && (
        <button
          onClick={() => setOpen(true)}
          className="rounded-xl bg-brand-green px-4 py-2.5 text-sm font-bold text-black hover:bg-brand-green2"
        >
          + Agregar gratis
        </button>
      )}

      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4" onClick={close}>
          <div
            onClick={(e) => e.stopPropagation()}
            className="max-h-[85vh] w-full max-w-md overflow-y-auto rounded-2xl border border-brand-border bg-brand-card p-6"
          >
            <h3 className="mb-1 text-lg font-bold text-white">{isEdit ? "Editar anuncio" : "Agregar anuncio gratis"}</h3>
            <p className="mb-4 text-xs text-brand-muted">
              {isEdit ? "Los cambios se aplican de inmediato." : "Sin pago — queda activo de inmediato."}
            </p>

            <label className={label}>Tipo</label>
            <div className="mb-3 flex gap-2">
              {([["banner_home", "Banner de inicio"], ["profile_ad", "Anuncio de perfil"]] as const).map(([k, l]) => (
                <button
                  key={k}
                  onClick={() => setType(k)}
                  className={`flex-1 rounded-lg border px-3 py-2 text-xs font-medium ${
                    type === k ? "border-brand-green bg-brand-green/10 text-brand-green" : "border-brand-border text-brand-muted"
                  }`}
                >
                  {l}
                </button>
              ))}
            </div>

            <label className={label}>Título</label>
            <input className={input} value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Ej. Nueva canción" />

            <label className={label}>Subtítulo (opcional)</label>
            <input className={input} value={subtitle} onChange={(e) => setSubtitle(e.target.value)} />

            <label className={label}>Imagen o video (opcional)</label>
            {existingMediaUrl && !file && (
              <p className="mb-1.5 text-[11px] text-brand-muted">Ya tiene {existingMediaType === "video" ? "un video" : "una imagen"} — elige un archivo para reemplazarlo.</p>
            )}
            <input
              type="file"
              accept="image/*,video/*"
              onChange={(e) => setFile(e.target.files?.[0] ?? null)}
              className="mb-3 block w-full text-sm text-brand-muted"
            />

            <label className={label}>Texto del botón (opcional)</label>
            <input className={input} value={buttonText} onChange={(e) => setButtonText(e.target.value)} placeholder="Ej. Ver más" />

            <label className={label}>Link al tocar el botón (opcional)</label>
            <input className={input} value={linkUrl} onChange={(e) => setLinkUrl(e.target.value)} placeholder="https://…" />

            <div className="mb-3 grid grid-cols-2 gap-3">
              <div>
                <label className={label}>País{lockedCountry ? "" : " (opcional)"}</label>
                {lockedCountry ? (
                  <div className={`${input} flex items-center opacity-80`}>{lockedCountry}</div>
                ) : (
                  <select value={country} onChange={(e) => { setCountry(e.target.value); setState(""); }} className={input}>
                    <option value="">Internacional (todos)</option>
                    {COUNTRIES.map((c) => <option key={c} value={c}>{c}</option>)}
                  </select>
                )}
              </div>
              <div>
                <label className={label}>Estado (opcional)</label>
                <input className={input} value={state} onChange={(e) => setState(e.target.value)} placeholder="Ej. Jalisco" disabled={!country} />
              </div>
            </div>

            <div className="mb-4 grid grid-cols-2 gap-3">
              <div>
                <label className={label}>Días activo</label>
                <input type="number" min={1} className={input} value={durationDays} onChange={(e) => setDurationDays(e.target.value)} />
              </div>
              <div>
                <label className={label}>Etiqueta (opcional)</label>
                <input className={input} value={tag} onChange={(e) => setTag(e.target.value)} placeholder="Ej. Promoción" />
              </div>
            </div>

            <div className="flex gap-3">
              <button onClick={close} className="flex-1 rounded-lg border border-brand-border py-2.5 text-sm text-brand-muted">Cancelar</button>
              <button onClick={submit} disabled={saving} className="flex-1 rounded-lg bg-brand-green py-2.5 text-sm font-bold text-black disabled:opacity-50">
                {saving ? "…" : "Publicar"}
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}

const input = "mb-3 w-full rounded-lg border border-brand-border bg-brand-bg px-3 py-2 text-sm text-white placeholder:text-brand-muted disabled:opacity-50";
const label = "mb-1 block text-xs font-medium text-brand-muted";

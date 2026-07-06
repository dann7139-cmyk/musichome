// ============================================================
// src/utils/support.ts
// Canal de soporte central — un solo lugar para el correo, el número
// de WhatsApp y el horario. Reutilizado por Profile, EventTimer y las
// tarjetas de eventos.
// ============================================================
import { Alert, Linking } from 'react-native';

// ⚙️ CORREO DE SOPORTE — ÚNICO lugar para cambiarlo cuando se defina el
//    definitivo. (Antes estaba inconsistente: .mx en Profile, .com en Plus.)
export const SUPPORT_EMAIL = 'soporte@daricefy.com';

// Número de WhatsApp en formato wa.me (sin '+', con lada país).
export const SUPPORT_WHATSAPP_NUMBER = '523332431680';

// Horario visible de atención.
export const SUPPORT_HOURS = 'Lun–Sáb 9am–8pm';

// Construye el cuerpo del mensaje, pre-identificado con el contexto
// (ej. el folio del evento) para que soporte sepa de qué se trata.
function buildMessage(context?: string): string {
  return context
    ? `Hola, necesito ayuda con ${context}`
    : 'Hola, necesito ayuda con Daricefy';
}

// Abre WhatsApp con el mensaje pre-cargado; si falla, cae a correo.
export function openSupportWhatsApp(context?: string): void {
  const url = `https://wa.me/${SUPPORT_WHATSAPP_NUMBER}?text=${encodeURIComponent(buildMessage(context))}`;
  Linking.openURL(url).catch(() => openSupportEmail(context));
}

// Abre el cliente de correo con asunto pre-cargado.
export function openSupportEmail(context?: string): void {
  const subject = context ? `Soporte Daricefy — ${context}` : 'Soporte Daricefy';
  const url = `mailto:${SUPPORT_EMAIL}?subject=${encodeURIComponent(subject)}`;
  Linking.openURL(url).catch(() => {});
}

// Menú "¿Necesitas ayuda?" — ofrece WhatsApp o correo con el folio ya
// pre-cargado. `context` p.ej.: `el evento DRC-2026-0017`.
export function openSupport(context?: string): void {
  Alert.alert(
    '¿Necesitas ayuda?',
    context
      ? `Sobre: ${context}\n\nElige cómo contactarnos. Horario: ${SUPPORT_HOURS}.`
      : `Elige cómo contactar a soporte. Horario: ${SUPPORT_HOURS}.`,
    [
      { text: '💬 WhatsApp', onPress: () => openSupportWhatsApp(context) },
      { text: '📧 Correo',   onPress: () => openSupportEmail(context) },
      { text: 'Cancelar', style: 'cancel' },
    ],
  );
}

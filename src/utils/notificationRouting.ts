/**
 * Ruteo compartido para notificaciones de solicitudes al GRUPO
 * (type 'booking' con screen 'OpenRequests' — olas de sql/95/103/108).
 *
 * El payload no distingue exprés vs programada, así que se consulta la
 * solicitud real: si es exprés (o el payload no trae request_id pero el
 * lookup falla), se revive el carrusel exprés — es el único camino de
 * recuperación de los follow-ups "podría irse a otro grupo". Si es
 * programada, abre el carrusel 📅 sobre el dashboard.
 *
 * Usado por: AppNavigator (push caliente + arranque en frío) y
 * NotificationsScreen (campanita). Un solo lugar para esta política.
 */
import { supabase } from '../config/supabase';
import { reviveAllExpressDispatches } from '../context/ExpressContext';
import { openScheduledQuotes } from '../components/requests/ScheduledQuotesCarousel';

export async function openForRequestNotification(requestId?: string): Promise<void> {
  if (requestId) {
    try {
      // Auditoría 2026-09-27: antes se consultaba `event_requests.is_express`, una
      // columna que NO existe en el esquema (ni en ninguna otra tabla). supabase-js
      // no lanza en ese caso: devuelve { data: null, error: 42703 }, así que el
      // try/catch nunca entraba y `isExpress` era SIEMPRE false → todas las
      // notificaciones de solicitud abrían el carrusel de programadas.
      // La forma canónica de saber si la solicitud llegó a ESTE grupo por el canal
      // exprés es la misma que usa el backend en sql/366: que exista un
      // `express_dispatches` suyo todavía vivo. Solo `dispatch_express_request`
      // crea esas filas (y es también quien pone `express_window_until`), así que
      // es el marcador real del canal. RLS (group_select_own_dispatches) ya limita
      // las filas al grupo del usuario, por eso no hace falta filtrar por group_id.
      const DISPATCH_MUERTOS = ['expired', 'ignored', 'taken'];
      const { data } = await supabase
        .from('express_dispatches')
        .select('status')
        .eq('request_id', requestId);
      const isExpress = (data ?? []).some(
        (d: any) => !DISPATCH_MUERTOS.includes(String(d?.status)),
      );
      if (isExpress) {
        await reviveAllExpressDispatches();
        return;
      }
      openScheduledQuotes(requestId);
      return;
    } catch {
      // lookup falló → caer al comportamiento seguro de abajo
    }
  }
  // Sin request_id no hay forma de saber el tipo: revivir exprés (si el
  // grupo tiene dispatches se los muestra) Y abrir programadas si hay algo
  // pendiente — el que tenga contenido gana la pantalla.
  void reviveAllExpressDispatches();
  openScheduledQuotes();
}

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
      const { data } = await supabase
        .from('event_requests')
        .select('is_express')
        .eq('id', requestId)
        .maybeSingle();
      const isExpress = data?.is_express === true || (data as any)?.is_express === 'true';
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

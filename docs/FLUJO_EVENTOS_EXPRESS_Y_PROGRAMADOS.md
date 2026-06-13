# Daricefy — Flujo completo de eventos Express y Programados

> Documento funcional verificado contra el código real de la app (junio 2026).
> Cubre: solicitud del cliente, vista del grupo, cotización, pago, expiración,
> notificaciones, día del evento, temporizador, horas extra y finalización.

---

## 1. Las tres formas en que un cliente contrata

| Vía | Pantalla | Para qué |
|---|---|---|
| **Express** ("Solicitar grupo ahora") | OpenRequestScreen | Evento HOY — llega a varios grupos en tiempo real, tipo Uber |
| **Solicitud guiada** | GuidedRequestScreen | Mismo flujo express pero en wizard de 3 pasos, con dirección elegida en mapa |
| **Cotización a un grupo específico** | QuoteFormScreen (desde el perfil del grupo) | Evento programado con fecha futura — el grupo cotiza y el cliente decide |

También existe **reserva directa de paquete** (BookingScreen): el cliente compra un paquete publicado con precio fijo, sin cotización.

---

## 2. Qué llena el cliente

### Express / Guiada
- Género musical (14 opciones) y tipo de evento (boda, cumpleaños, fiesta, empresarial, graduación, serenata, otro)
- Fecha = **hoy** (es inmediata), hora de inicio (selector), duración 3–8 h, número de invitados
- Ciudad/estado **autodetectados por GPS** (editables)
- Dirección: en la guiada se elige **con pin en el mapa** (guarda lat/lng exactos); en la express se escribe y se confirma
- ¿Espacio techado? (sí/no/no sé), tamaño del lugar (patio/salón/jardín/escenario), ¿necesita sonido? (sí/no/ya tengo)
- Comentarios con **filtro anti-contacto**: bloquea números de teléfono y números escritos en palabras (nadie puede saltarse la plataforma)
- Si hay alta demanda, se muestra aviso de **surge pricing** por género/ciudad

### Cotización programada
- Tipo de evento, **fecha futura en calendario**, hora, duración mínima 3 h, invitados
- Dirección con mapa o manual, techado, tamaño, sonido, comentarios (misma moderación)
- El descanso NO lo elige el cliente — lo decide el grupo al iniciar el evento

---

## 3. Qué pasa al enviar una solicitud express

1. Se inserta en `event_requests` con status `open`.
2. RPC `dispatch_express_request`: busca hasta **10 grupos** del mismo género, en la misma ciudad o mismo estado, activos y sin suspensión por strikes → crea un "dispatch" por grupo con **ventana de exclusividad de 3 minutos**.
3. **Push inmediata (1–5 segundos)** vía trigger + Expo Push, con cron de respaldo cada 60 s (sin duplicados).
4. Si el canal express no alcanzó a ningún grupo → fallback automático: notificación por olas (`notify_wave_1`) a grupos del género en un radio de 50 km.
5. Un cron libera los locks express vencidos **cada minuto**.

---

## 4. Cómo lo ve el grupo (con mapa)

### Express — IncomingExpressScreen
- Pantalla completa con **sonido y vibración**: mapa oscuro con la ruta desde su posición GPS hasta la **zona aproximada** del evento.
- **Privacidad**: el pin del destino lleva un desplazamiento aleatorio — la dirección exacta NUNCA se muestra antes del pago.
- Countdown de 3 minutos (tiembla cuando es crítico). Datos: tipo de evento, género, hora, horas, invitados, ciudad/municipio, techado, sonido, comentarios.
- En Realtime: si otro grupo cotizó y el cliente ya aceptó → pantalla "Ya fue tomado" (muestra a cuántos grupos llegó). Si su cotización salió bien → animación de éxito.

### Programadas — OpenRequestsScreen (grupo)
- Lista de solicitudes abiertas que coinciden con su género. Mapa con **radio aproximado de ~2 km** sobre el centro de la ciudad — la dirección exacta solo se revela cuando el cliente paga.

---

## 5. Cómo cotiza el grupo

### Express → ProposeRequestScreen
- Llena su propuesta de precio → RPC `propose_event_request` guarda la cotización y la solicitud pasa a `en_negociacion` (exclusiva de ese grupo mientras el cliente decide).

### Programada → QuotesScreen → QuoteDetailScreen
- Ve todas las cotizaciones recibidas con estado: Pendiente / Cotizado / Aceptado / Rechazado / Expirado.
- Llena: **precio por hora** (calcula el total base), **precio de hora extra** (1h/2h/3h — es lo que pagará el cliente si extiende) y **notas** ("incluye sonido", "no incluye transporte de equipo"...).
- Al enviar: la cotización pasa a `quoted` y el cliente recibe notificación.

---

## 6. Cómo ve el cliente la cotización

- **Express**: banner ⚡ en el Home ("propuesta recibida") + tab "Mis solicitudes" con estados claros (⏳ Esperando grupo / 🤝 Grupo interesado / ✅ Confirmada / ❌ Cancelada / ⌛ Expirada).
  - **Aceptar** → RPC `client_accept_proposal` crea la reserva y lo lleva directo a pagar (Stripe). Si el evento ya fue confirmado por otra vía, le avisa "Ya contratado".
  - **Rechazar** → la solicitud **vuelve a `open`** para que otros grupos puedan proponerse.
- **Programada**: ClientQuoteDetailScreen — desglose completo, opción de **meses sin intereses** (con recargo público transparente), botones Aceptar (→ pago con Stripe PaymentSheet, pago completo) o Rechazar.

El dinero queda **retenido** en la plataforma (payout `held`) — no le llega al grupo hasta cumplir el evento.

---

## 7. ¿Qué pasa si nadie contesta? (expiración — NADA se borra)

Cron `expire_stale_requests` corre **cada 5 minutos** con estas reglas exactas:

| Situación | Resultado |
|---|---|
| Solicitud `open` sin actividad por **60 min** | → `expired` + notificación al cliente ("no recibió respuesta a tiempo") |
| `en_negociacion` y el cliente no respondió la propuesta en **30 min** | → vuelve a `open` (otros grupos pueden proponer) + notificación al cliente |
| Cualquier solicitud que pasó su `expires_at` | → `expired` |
| Reserva que el grupo no respondió en **24 h** | → auto-cancelada (cron cada 5 min) + notificación |
| Cliente que no pagó a tiempo | → `booking_expired_no_payment` |

**Importante: nunca se borra nada.** Las solicitudes y reservas quedan en la base con su estado final (`expired`, `cancelled`, `completed`...). El cliente las sigue viendo en "Mis solicitudes" y el grupo en su historial. Esto es a propósito: es el respaldo para pagos, disputas y auditoría.

---

## 8. Cómo ve el grupo sus eventos (recientes y anteriores)

- **GroupEventsScreen** (tab Eventos): "Próximos" (reservas pagadas/en curso — abren el temporizador) y "Pendientes" (cotizaciones por responder).
- **ReservationsScreen**: tabs **Activas / Historial / por estado**. El historial son todas las que ya pasaron de fecha — se muestran atenuadas pero **permanecen para siempre**.
- El corte próximos/historial usa la **hora de Ciudad de México**, no la del teléfono.

---

## 9. Notificaciones

- Toda notificación se inserta en la tabla `notifications` → aparece en la campana de la app **y** un cron cada minuto la despacha como **push real al teléfono aunque la app esté cerrada** (Expo Push).
- Las express además llevan **push instantánea** desde el trigger (1–5 s); el cron solo es respaldo y no duplica.
- Cobertura: solicitud nueva en tu zona, propuesta recibida, reserva confirmada/rechazada/expirada, pago recibido, **recordatorios 24 h / 3 h / 1 h antes del evento**, grupo llegó, evento inició, descansos, horas extra, pago liberado, disputas.

---

## 10. Día del evento — flujo del grupo (EventTimerScreen)

1. **En camino**: no hay botón — el sistema lo infiere. En el mapa en vivo del admin, el grupo con reserva activa y GPS aparece como 🚗 En camino (arco naranja express / púrpura programada) hasta que marca llegada.
2. **📍 "Llegué al evento"**: confirma con alerta → se guarda `group_arrived_at` → **se libera el 50% de sus ganancias al wallet** → notificación al cliente ("El grupo ha llegado"), a los admins y a los integrantes del grupo.
3. **▶️ "Iniciar evento"**: habilitado desde **30 min antes** de la hora pactada. Pasada la hora exacta, el botón manual se bloquea porque entra el **auto-inicio**: si ya marcó llegada y pasan 10 minutos de la hora, el evento arranca solo (ventana de 6 h). *El grupo no puede "olvidar" iniciar el timer.*
4. Al iniciar elige el **tipo de descanso**: A (15 min por hora), B (15 min a la mitad), C (20 min a la mitad), D (sin descanso) → la reserva pasa a `in_progress` y el cliente recibe "🎵 ¡Tu evento ha iniciado!".
5. **Recovery a prueba de fallos**: si la app se cerró, al volver a abrir lee el estado real de la base — reanuda el timer donde va, auto-inicia si correspondía, o cierra y cobra si el tiempo ya se agotó mientras estuvo cerrada.

---

## 11. El temporizador (cliente y grupo)

- **No es un contador local frágil**: ambos teléfonos calculan contra `event_started_at` guardado en la base. Se puede cerrar la app, quedarse sin batería o re-entrar — el tiempo se recalcula exacto y **cliente y grupo siempre ven el mismo reloj** (sincronía por Realtime).
- Todo el cálculo usa **hora fija de México (UTC-6)**.
- El anillo muestra el tiempo de **música** (los descansos no descuentan tiempo de música): verde EN VIVO, naranja EN DESCANSO, naranja cuando queda <25%, rojo <10%.
- **Avisos automáticos durante el evento**:
  - A las 2 h de música → oferta de horas extra al cliente
  - 30 min antes del fin → oferta de horas extra
  - 15 min antes del fin → aviso al cliente **y su modal de horas extra se abre solo**
  - 3 min antes de terminar cada descanso → aviso a cliente y músicos ("vuelven a tocar")
  - Al arrancar cada hora extra → aviso a cliente ("¡tu hora extra inicia!") y a los músicos ("🔥 a darlo todo")
- Si el tiempo se pasó sin extensión, el cliente ve el badge "⚠️ FUERA DE CONTRATO".

---

## 12. Horas extra (doble confirmación)

1. **Cliente** (modal en su pantalla de evento en vivo — se abre solo a 15 min del fin, o desde la notificación): elige **1, 2 o 3 horas** al precio de hora extra de la cotización/paquete → RPC `request_extra_hours_client` → queda "⏳ Esperando al grupo".
2. **Grupo**: le aparece modal en Realtime con el **desglose** (tarifa de servicio de plataforma y cuánto le queda al grupo) y una **validación de agenda**: si la extensión no deja un buffer de 2 h antes de su siguiente evento del día, no puede aceptar.
3. **Acepta** → `group_confirm_extra_hours` + `credit_extra_hour_earnings` (su ganancia se acredita al wallet) → **el timer se extiende en vivo en los dos teléfonos** (cada hora extra = 60 min de música + 15 de descanso) → cliente notificado "✅ Hora extra confirmada". **Rechaza** → cliente notificado "no disponible en este momento".
4. **Cobro**: contra el saldo a favor del cliente (la tarifa de servicio del 10% genera saldo usable para extras). Si el cobro automático no procede, al finalizar el grupo registra cómo cobró el saldo: Efectivo / Tap to Pay / Transferencia.

---

## 13. Finalización

- **Automática**: cuando el tiempo de música llega a cero, el evento se cierra solo → `completed`, con la duración real guardada. (También funciona si la app estaba cerrada — recovery al abrir.) El grupo también puede finalizar manualmente.
- Se libera el **resto de las ganancias** (el otro 50%, o el 100% si nunca marcó llegada) — bloqueado automáticamente si hay disputa abierta.
- Pantalla de celebración con el **desglose de pago a cada integrante** (event_payouts).
- Si no hubo horas extra: el cliente recibe "🎵 ¿Quieres más música?" para extender post-evento.
- **Calificaciones en cadena**: el grupo califica al cliente y a los talentos invitados por tocada; el cliente califica al grupo.
- El dinero del grupo: `pending` → `released` → lo retira desde su Wallet (solicitud de payout).

---

## 14. Protecciones anti-error ya implementadas

- **Anti double-booking**: trigger en base de datos — un grupo no puede tener 2 reservas activas el mismo día.
- **Buffer de agenda** de 2 h al aceptar horas extra si hay otro evento después.
- Dirección exacta **solo tras el pago** (antes: zona aproximada).
- Filtro anti-teléfonos en todos los campos de texto libre.
- Locks express liberados por cron cada minuto (nadie se queda "atorado").
- Timers calculados contra la base de datos, no contra el reloj local.
- Notificaciones con constraint de tipos completo (un tipo faltante ya no rompe el push).
- Comisión/tarifa de servicio: 10% fijo, sin doble cobro en horas extra (corregido en sql/241).

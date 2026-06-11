# Daricefy — Flujos Completos Paso a Paso

---

## FLUJO EXPRESS (Solicitud Inmediata — tipo Uber)

### CLIENTE

**Paso 1 — HomeScreen**
- Ve la pantalla principal con carrusel de grupos y buscador
- Toca el botón "⚡ Solicitar ahora" o el botón "Solicitud guiada"
- Ambos llevan a GuidedRequestScreen

**Paso 2 — GuidedRequestScreen (Paso 1: Tipo de evento)**
- Ve una cuadrícula de 7 tarjetas con emoji: Boda, Cumpleaños, Fiesta, Empresarial, Serenata, Graduación, Otro
- Toca una tarjeta → avanza automáticamente al paso 2 (200ms delay)

**Paso 3 — GuidedRequestScreen (Paso 2: Detalles del evento)**
- Indicador de progreso: 3 puntos en la parte superior (el actual en verde)
- Elige género musical (chips con emoji): Norteño, Banda, Mariachi, Grupero, etc.
- Ciudad detectada automáticamente por GPS (card verde). Puede tocar "Editar" para cambiarla manualmente
- Elige hora de inicio (abre TimePickerModal — rueda de horas/minutos)
- Escribe número de invitados (teclado numérico)
- Elige duración (chips: 3h, 4h, 5h, 6h, 8h+)
- Toca "Continuar →" (desactivado hasta que todos los campos estén llenos)

**Paso 4 — GuidedRequestScreen (Paso 3: Lugar)**
- Toca "📍 Seleccionar en el mapa" → se abre MapAddressPicker (pantalla completa)
  - Mapa interactivo: el usuario mueve el mapa, el pin rojo queda fijo al centro
  - Barra de búsqueda en la parte superior (busca por nombre de calle)
  - Card inferior oscura muestra la dirección detectada automáticamente
  - Botón "✅ Confirmar esta dirección" → regresa a GuidedRequestScreen con dirección guardada
- Elige: ¿Espacio techado? (Sí / No / No sé)
- Elige tamaño del lugar (cuadrícula 2×2: Patio pequeño / Salón mediano / Jardín grande / Escenario profesional)
- Elige: ¿Necesitas sonido? (Necesito / No necesito / Ya tengo sonido)
- Escribe comentarios adicionales (opcional, máx 500 chars)
- Ve resumen de la solicitud (card con borde verde translúcido)
- Toca "⚡ Enviar solicitud a grupos"
  → Se inserta en `event_requests` con latitude/longitude
  → RPC `notify_wave_1` notifica a los top grupos del género en un radio de 50km

**Paso 5 — Alerta de confirmación**
- Aparece: "✅ Solicitud enviada — Tu solicitud llegó a X grupos de [género]"
- Toca "Ver solicitudes" → navega a OpenRequestScreen (tab "Mis solicitudes")

**Paso 6 — OpenRequestScreen (tab: Mis solicitudes)**
- Ve la solicitud con badge "⏳ Esperando grupo"
- Cuando un grupo propone precio: badge cambia a "🤝 Grupo interesado"
- La card se expande y muestra:
  - Foto + nombre + ciudad del grupo
  - Botón "Ver perfil →"
  - Desglose de precio: precio/hora × horas = subtotal → traslado → **Total** (en amarillo)
  - Hora de llegada del grupo / hora de inicio de la música
  - Nota informativa del grupo
  - Dos botones: "❌ Buscar otro" | "✅ Contratar"
- Toca "✅ Contratar"
  → RPC `client_accept_proposal()` crea reserva en status `'accepted'` directamente
  → Se llama a Edge Function `create-payment-intent`
  → Se abre **Stripe Payment Sheet** (modal nativo oscuro)
  → Cliente ingresa tarjeta y paga el 50% de anticipo
  → Pago exitoso: `reservations.status = 'confirmed'`, `payment_status = 'deposit_paid'`
  → Notificación al grupo: "💰 Anticipo recibido"
  → Navega a ClientReservationsScreen

**Paso 7 — ReservationsScreen (cliente)**
- Ve la reserva con badge verde "Confirmada"
- Al tocar la card → navega a EventTimerScreen (modo solo lectura — ve el temporizador del evento)

---

### GRUPO (flujo Express)

**Paso 1 — Recibe notificación push**
- "⚡ Nueva solicitud de [género] en [ciudad]"

**Paso 2 — GroupOpenRequestsScreen**
- Ve lista de solicitudes abiertas que coinciden con su género
- Cada card muestra: tipo de evento, fecha, duración, número de invitados, ciudad
- Indicador de tiempo restante antes de que expire (cuenta regresiva)
- Toca una solicitud → se abre un modal/panel de detalle

**Paso 3 — Modal de detalle de solicitud**
- Mapa oscuro con círculo de ~2km sobre la ciudad (NO la dirección exacta)
- Detalles completos: tipo, fecha, hora, duración, invitados, techado, tamaño, sonido, comentarios
- Ruta desde ubicación del grupo hasta la zona del evento
- Toca "Proponer precio"

**Paso 4 — GroupProposeRequestScreen**
- Llena: precio por hora, costo de traslado, hora de llegada, hora de inicio de la música, notas
- Toca "Enviar propuesta"
  → `event_requests.status = 'en_negociacion'`
  → Notificación al cliente: "🤝 Un grupo está interesado"

**Paso 5 — Cuando cliente acepta y paga**
- Notificación: "💰 Anticipo recibido — El evento está confirmado"
- El grupo navega a GroupReservationsScreen → ve la reserva confirmada

**Paso 6 — EventTimerScreen (día del evento)**
- Ve la pantalla del temporizador con los datos de la reserva
- Toca "📍 Llegué al lugar"
  → Se graba `group_arrived_at` en la BD
  → El botón desaparece y aparece "▶ Iniciar evento" (disponible 5 min antes de la hora)
- Toca "▶ Iniciar evento" (o el timer se auto-inicia 10 min después de la hora si el grupo ya llegó)
  → `event_started_at` se graba en BD
  → El temporizador empieza a correr
  → Aparece el **mapa exacto** del cliente (solo después del pago)
  → El mapa es interactivo: zoom + scroll habilitados
  → Botón "📍 Abrir en Google Maps" para navegar
- El timer corre mostrando tiempo transcurrido + segmento actual (MÚSICA / DESCANSO)
- La app detecta automáticamente cuando se cumple el tiempo contratado
  → Mueve reserva a `status = 'completed'`
  → Aparece pantalla de celebración 🎉 con distribución de pago

---

## FLUJO PROGRAMADO (Cotización Personalizada)

### CLIENTE

**Paso 1 — HomeScreen**
- Ve carrusel de grupos recomendados
- Toca una tarjeta de grupo → GroupDetailScreen

**Paso 2 — GroupDetailScreen**
- Ve perfil completo: foto, video promo, descripción, géneros, rating, paquetes disponibles
- Toca "Cotizar" en un paquete (ej: "Paquete 4h — $5,000")
- → Navega a QuoteFormScreen con los datos del grupo y paquete

**Paso 3 — QuoteFormScreen**
- Formulario de 10 secciones (scroll vertical):
  1. Tipo de evento (chips con emoji)
  2. Ubicación — toca "📍 Seleccionar en el mapa" → MapAddressPicker
  3. Fecha — toca para abrir calendario (react-native-calendars, tema oscuro)
  4. Hora de inicio — TimePickerModal
  5. Duración (mín 3h — chips)
  6. Número de personas
  7. ¿Techado? (chips)
  8. Espacio (chips)
  9. ¿Necesitas sonido? (chips)
  10. Comentarios adicionales
- Toca "Enviar solicitud de cotización"
  → INSERT en `quotes` con `latitude`, `longitude`, todos los datos
  → Notificación al grupo (owner + integrantes + invitados de trabajo)
  → Alerta: "✅ Solicitud enviada — Te notificaremos cuando el grupo responda"

**Paso 4 — ReservationsScreen → tab Cotizaciones**
- Ve la cotización con status "Pendiente respuesta del grupo"
- Cuando el grupo responde: badge cambia + notificación push

**Paso 5 — ClientQuoteDetailScreen**
- Ve la cotización que el grupo mandó:
  - Card grande con total en verde (Syne 26px)
  - Detalles del evento (tipo, fecha, duración, hora)
  - Horas extra disponibles con precios (+1h, +2h, +3h)
  - Notas del grupo (en cursiva)
- Toca "Contratar y pagar"
  → Alerta de confirmación: "Pagarás $X,XXX MXN ahora (50%). El resto lo pagas el día del evento"
  → Confirma → crea `event` + `reservation` en BD → lanza Stripe
  → **Stripe Payment Sheet** → cliente paga 50%
  → Si cierra sin pagar: reserva queda creada, puede pagar desde "Mis Eventos"
  → Si pago exitoso → navega a ClientReservationsScreen

**Paso 6 — ReservationsScreen**
- Ve reserva confirmada
- Al tocar → EventTimerScreen en modo solo lectura (ve el temporizador en tiempo real)

---

### GRUPO (flujo Programado)

**Paso 1 — GroupQuotesScreen**
- Lista de cotizaciones recibidas de clientes
- Badge con count de pendientes sin responder

**Paso 2 — GroupQuoteDetailScreen**
- Cabecera: tipo de evento, fecha, hora, invitados
- Datos del lugar: dirección, municipio, estado, techado, tamaño, sonido
- Sección "Tu cotización" (campos que el grupo llena):
  - Precio por hora → calcula total automáticamente
  - Desglose en tiempo real: precio base → comisión 10% → **tus ganancias** (verde)
  - Costo de traslado
  - Horas extra (3 campos OBLIGATORIOS: +1h, +2h, +3h) — cada uno muestra el 10% descontado
  - Número de integrantes + distribución de ganancias entre ellos
  - Notas del grupo
- Botones: "Rechazar" (borde rojo) | "Enviar cotización" (verde)

**Paso 3 — ConfirmBookingScreen (cuando cliente acepta)**
- El grupo ve el resumen de la reserva
- Toca "Confirmar" → `reservations.status = 'accepted'`
- (En el flujo programado, la reserva empieza en `pending_group_confirmation` y el grupo debe confirmar)

**Paso 4 — Cuando cliente paga**
- Notificación: "💰 Anticipo recibido"
- GroupReservationsScreen → ve la reserva confirmada

**Paso 5 — EventTimerScreen (igual al flujo Express)**
- Mismo flujo: Llegué → Iniciar → Timer → Auto-fin → Celebración

---

## DIFERENCIA CLAVE ENTRE LOS DOS FLUJOS

| Aspecto | Express | Programado |
|---|---|---|
| El cliente elige al grupo | No (el primero que acepta gana) | Sí (cotiza a grupo específico) |
| El grupo fija el precio | Sí (propone precio) | Sí (responde cotización) |
| Confirmación del grupo | NO necesaria (reserva = `accepted` directo) | SÍ (el grupo confirma antes de que el cliente pague) |
| Fecha del evento | Siempre hoy | Cualquier fecha futura |
| Dirección exacta | Solo visible tras el pago | Solo visible tras el pago |
| Mapa en OpenRequests | Zona ~2km (círculo) | No aplica |
| Mapa en EventTimer | Exacto (lat/lng del event_request) | Exacto (lat/lng del quote) |

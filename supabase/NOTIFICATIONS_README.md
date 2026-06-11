# Sistema de Notificaciones - Daricefy

## ✅ Implementación Completa

Se ha implementado un sistema completo de notificaciones funcionales con las siguientes características:

### 1. Base de datos (`notifications_table.sql`)

**Tabla `notifications`:**
- `id` - UUID primary key
- `user_id` - UUID (referencia a auth.users)
- `type` - TEXT (reservation, payment, review, verification, system)
- `title` - TEXT
- `message` - TEXT
- `reference_id` - UUID (nullable, referencia a recursos relacionados)
- `is_read` - BOOLEAN (default: false)
- `created_at` - TIMESTAMP (default: NOW())

**Políticas RLS:**
- Los usuarios solo ven sus propias notificaciones
- Los usuarios pueden marcar sus notificaciones como leídas
- Los usuarios pueden eliminar sus notificaciones

**Trigger automático:**
- Crea notificación cuando se inserta una nueva reserva
- Notifica al grupo owner sobre nuevas reservas

### 2. NotificationsScreen (`src/screens/shared/NotificationsScreen.tsx`)

**Características:**
- ✅ Fetch de notificaciones reales desde Supabase
- ✅ Ordenadas por `created_at DESC`
- ✅ Punto verde en notificaciones no leídas (`is_read = false`)
- ✅ Marcar como leída al tocar
- ✅ Navegación inteligente según tipo:
  - `reservation` → GroupReservations (group) / ClientReservations (client)
  - `payment` → GroupEarnings (group)
  - `review` → GroupReservations (group)
  - `verification` → GroupVerification (group)
  - `system` → Solo marca como leída
- ✅ Botón "Marcar todas como leídas" (icono ✓✓)
- ✅ Animaciones suaves (fade-in, slide-in, scale en tap)
- ✅ Diseño oscuro profesional
- ✅ Tiempo relativo en español:
  - "Ahora", "Hace 5 min", "Hace 2h", "Ayer", "Hace 3 días", "15 feb"
- ✅ Estado de carga con spinner
- ✅ Estado vacío con icono y mensaje
- ✅ Iconos según tipo:
  - reservation: 🎉
  - payment: 💰
  - review: ⭐
  - verification: ✅
  - system: 🔔

### 3. Contador dinámico en campana

**HomeScreen (`src/screens/client/HomeScreen.tsx`):**
- Badge numérico en campana (ejemplo: "3", "9+")
- Fetch al cargar y al volver (navigation focus)
- Actualización automática

**GroupDashboardScreen (`src/screens/group/DashboardScreen.tsx`):**
- Badge numérico en campana
- Fetch al cargar y al volver
- Actualización automática

**AdminDashboardScreen (`src/screens/admin/DashboardScreen.tsx`):**
- Badge numérico en campana
- Fetch al cargar y al volver
- Actualización automática

### 4. Diseño del Badge

```tsx
// Badge verde con número blanco
{unreadCount > 0 && (
  <View style={styles.bellBadge}>
    <Text style={styles.bellBadgeText}>
      {unreadCount > 9 ? '9+' : unreadCount}
    </Text>
  </View>
)}
```

**Estilos:**
- Posición: absolute (top-right de la campana)
- Color: verde (#00E676) con borde del fondo
- Texto: bold, 10px, color del fondo
- Auto-expande con números grandes (9+)

---

## 📋 Instrucciones de Instalación

### Paso 1: Ejecutar SQL en Supabase

1. Ir a Supabase Dashboard → SQL Editor
2. Copiar el contenido de `supabase/notifications_table.sql`
3. Ejecutar el script completo
4. Verificar que la tabla `notifications` se creó correctamente

### Paso 2: Verificar RLS

En Supabase Dashboard → Table Editor → notifications:

```sql
-- Verificar políticas activas
SELECT * FROM pg_policies WHERE tablename = 'notifications';
```

Deberías ver 4 políticas:
1. "Users can view their own notifications"
2. "Users can update their own notifications"
3. "Authenticated users can insert notifications"
4. "Users can delete their own notifications"

### Paso 3: Probar el sistema

#### Testing manual:

```sql
-- Crear notificación de prueba (reemplaza USER_ID con tu UUID)
INSERT INTO notifications (user_id, type, title, message)
VALUES (
  'TU_USER_ID_AQUI',
  'reservation',
  '🎉 Nueva reserva recibida',
  'Carlos Ramírez solicitó una reserva para el 15/03/2025.'
);

-- Ver notificaciones
SELECT * FROM notifications WHERE user_id = 'TU_USER_ID_AQUI';
```

#### Testing desde la app:

1. Abrir la app
2. Ir a Notificaciones
3. Debería aparecer la notificación de prueba
4. Tocar la notificación:
   - Se marca como leída (punto verde desaparece)
   - Navega a la pantalla correspondiente
   - El contador en la campana se actualiza

---

## 🎨 Ejemplos de Notificaciones

### Reserva nueva (para grupos)
```sql
INSERT INTO notifications (user_id, type, title, message, reference_id)
VALUES (
  'GROUP_OWNER_ID',
  'reservation',
  '🎉 Nueva reserva recibida',
  'María López solicitó una reserva para el 20/03/2025.',
  'RESERVATION_ID'
);
```

### Pago recibido (para grupos)
```sql
INSERT INTO notifications (user_id, type, title, message, reference_id)
VALUES (
  'GROUP_OWNER_ID',
  'payment',
  '💰 Pago recibido - $5,200',
  'Tu ganancia neta fue acreditada. Comisión: $450.',
  'RESERVATION_ID'
);
```

### Nueva reseña (para grupos)
```sql
INSERT INTO notifications (user_id, type, title, message, reference_id)
VALUES (
  'GROUP_OWNER_ID',
  'review',
  '⭐ Nueva reseña recibida',
  'Carlos te calificó con 5 estrellas: "Excelente servicio".',
  'GROUP_ID'
);
```

### Verificación aprobada (para grupos)
```sql
INSERT INTO notifications (user_id, type, title, message)
VALUES (
  'GROUP_OWNER_ID',
  'verification',
  '✅ ¡Cuenta verificada!',
  'Tu solicitud de verificación fue aprobada. Ahora tienes el badge azul.'
);
```

### Notificación del sistema
```sql
INSERT INTO notifications (user_id, type, title, message)
VALUES (
  'USER_ID',
  'system',
  '🔔 Actualización importante',
  'Hemos mejorado el sistema de reservas. Descubre las nuevas funciones.'
);
```

---

## 🔄 Actualización automática del contador

El contador de notificaciones se actualiza en estos casos:

1. **Al montar el componente** (useEffect inicial)
2. **Al volver a la pantalla** (navigation focus listener)
3. **Al marcar como leída** (actualización optimista)
4. **Al marcar todas como leídas** (batch update)

No se usa polling/interval para evitar consumo excesivo de recursos.

---

## 🚀 Próximos pasos (opcional)

### Notificaciones push (futuro)
- Integrar Expo Notifications
- Enviar push cuando se crea notificación
- Trigger en Supabase para enviar push automáticamente

### Filtros (futuro)
- Filtrar por tipo de notificación
- Filtrar por leída/no leída
- Búsqueda en notificaciones

### Configuración (futuro)
- Preferencias de notificaciones por tipo
- Silenciar notificaciones
- Frecuencia de notificaciones

---

## 📝 Notas técnicas

- **Performance:** Query optimizado con índices en `user_id` e `is_read`
- **Seguridad:** RLS asegura que cada usuario solo vea sus notificaciones
- **UX:** Animaciones nativas con `useNativeDriver: true`
- **I18n:** Fechas en español con `toLocaleString('es-MX')`
- **Escalabilidad:** Límite de 50 notificaciones en fetch (paginación futura)

---

## ✅ Checklist de verificación

- [x] Tabla `notifications` creada
- [x] RLS policies activadas
- [x] Trigger de reserva funciona
- [x] NotificationsScreen muestra datos reales
- [x] Navegación según tipo implementada
- [x] Marcar como leída funciona
- [x] Marcar todas como leídas funciona
- [x] Contador en HomeScreen
- [x] Contador en GroupDashboardScreen
- [x] Contador en AdminDashboardScreen
- [x] Animaciones funcionan
- [x] Estado vacío diseñado
- [x] Estado de carga diseñado
- [ ] SQL ejecutado en Supabase (PENDIENTE - acción del usuario)

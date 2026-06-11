# 🚀 Setup de Supabase - Instrucciones paso a paso

## ⚠️ IMPORTANTE: Debes ejecutar SQL en Supabase

Este proyecto requiere que ejecutes scripts SQL en tu base de datos de Supabase para crear tablas, triggers y políticas de seguridad.

---

## 📋 Paso 1: Ejecutar SQL

### 1.1 Abre Supabase SQL Editor

1. Ve a [Supabase Dashboard](https://supabase.com/dashboard)
2. Selecciona tu proyecto
3. En el menú lateral, click en **SQL Editor**
4. Click en **New Query**

### 1.2 Ejecuta el script

1. Abre el archivo: [`EJECUTAR_EN_SUPABASE.sql`](./EJECUTAR_EN_SUPABASE.sql)
2. Copia **TODO** el contenido del archivo
3. Pégalo en el SQL Editor de Supabase
4. Click en **Run** (o presiona `Ctrl + Enter`)

**Espera a que termine la ejecución.** Verás un mensaje de éxito.

---

## 📦 Paso 2: Crear Storage Buckets (Manual)

### 2.1 Bucket para fotos de grupos

1. En Supabase Dashboard → **Storage**
2. Click en **New bucket**
3. Configuración:
   - **Name:** `group-images`
   - **Public bucket:** ✅ **SÍ** (activado)
   - **Allowed MIME types:** `image/jpeg, image/png, image/webp`
   - **File size limit:** `5242880` (5 MB)
4. Click **Create bucket**

### 2.2 Bucket para videos promocionales

1. En Supabase Dashboard → **Storage**
2. Click en **New bucket**
3. Configuración:
   - **Name:** `group-videos`
   - **Public bucket:** ✅ **SÍ** (activado)
   - **Allowed MIME types:** `video/mp4, video/quicktime, video/webm`
   - **File size limit:** `52428800` (50 MB)
4. Click **Create bucket**

---

## ✅ Paso 3: Verificar que todo funciona

### 3.1 Verificar tabla notifications

En SQL Editor, ejecuta:

```sql
SELECT COUNT(*) FROM notifications;
```

✅ Si devuelve `0` (sin errores) → Todo bien

### 3.2 Verificar políticas RLS

```sql
SELECT COUNT(*) FROM pg_policies WHERE tablename = 'notifications';
```

✅ Debe devolver `4` (cuatro políticas)

### 3.3 Verificar trigger

```sql
SELECT COUNT(*) FROM information_schema.triggers
WHERE trigger_name = 'trigger_notify_reservation_created';
```

✅ Debe devolver `1`

### 3.4 Verificar buckets

1. Ve a **Storage**
2. Debes ver dos buckets:
   - ✅ `group-images`
   - ✅ `group-videos`

---

## 🧪 Paso 4: Testing (Opcional)

### Crear notificación de prueba

Primero obtén tu user ID:

```sql
SELECT id FROM auth.users LIMIT 1;
```

Copia el UUID que devuelve, luego ejecuta:

```sql
INSERT INTO notifications (user_id, type, title, message)
VALUES (
  'PEGA_AQUI_TU_USER_ID',
  'system',
  '🎉 ¡Sistema activo!',
  'Las notificaciones funcionan correctamente.'
);
```

Abre la app y ve a Notificaciones. Debes ver el mensaje de prueba.

---

## 📝 Checklist final

Marca cada item cuando esté completo:

### SQL ejecutado:
- [ ] Tabla `notifications` creada
- [ ] 4 políticas RLS activas
- [ ] Trigger `trigger_notify_reservation_created` activo
- [ ] Estado `rejected` permitido en reservations

### Storage buckets creados:
- [ ] `group-images` (5 MB, público)
- [ ] `group-videos` (50 MB, público)

### Testing:
- [ ] Notificación de prueba funciona
- [ ] Contador de notificaciones aparece en la campana
- [ ] Subir foto de grupo funciona
- [ ] Subir video funciona

---

## ❓ Problemas comunes

### "relation 'notifications' does not exist"
→ No ejecutaste el SQL. Ve al Paso 1.

### "permission denied for table notifications"
→ Las políticas RLS no se crearon. Ejecuta el SQL completo.

### "bucket not found: group-images"
→ No creaste el bucket. Ve al Paso 2.

### El trigger no se ejecuta
→ Verifica que esté activo:
```sql
SELECT * FROM information_schema.triggers
WHERE trigger_name = 'trigger_notify_reservation_created';
```

---

## 🎯 Siguiente paso

Una vez completado todo el checklist, la app está lista para usarse con:

✅ Sistema de notificaciones completo
✅ Upload de fotos de grupos
✅ Upload de videos promocionales
✅ Triggers automáticos
✅ Seguridad con RLS

**¡Todo listo para producción!** 🚀

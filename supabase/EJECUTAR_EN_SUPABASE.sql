-- ══════════════════════════════════════════════════════════════════════════════
-- INSTRUCCIONES: EJECUTAR TODO ESTE SCRIPT EN SUPABASE SQL EDITOR
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Ve a: Supabase Dashboard → SQL Editor → New Query
-- Copia y pega TODO este archivo
-- Click en "Run" o presiona Ctrl+Enter
--
-- ══════════════════════════════════════════════════════════════════════════════

-- ──────────────────────────────────────────────────────────────────────────────
-- 1. TABLA NOTIFICATIONS (Sistema de notificaciones)
-- ──────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.notifications (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type         TEXT NOT NULL CHECK (type IN ('reservation', 'payment', 'review', 'verification', 'system')),
  title        TEXT NOT NULL,
  message      TEXT NOT NULL,
  reference_id UUID,
  is_read      BOOLEAN NOT NULL DEFAULT false,
  created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Índices para performance
CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON public.notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON public.notifications(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_user_unread ON public.notifications(user_id, is_read) WHERE is_read = false;

-- RLS Policies
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own notifications"
ON public.notifications FOR SELECT
USING (auth.uid() = user_id);

CREATE POLICY "Users can update their own notifications"
ON public.notifications FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Authenticated users can insert notifications"
ON public.notifications FOR INSERT
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own notifications"
ON public.notifications FOR DELETE
USING (auth.uid() = user_id);

COMMENT ON TABLE notifications IS 'Sistema de notificaciones para usuarios';


-- ──────────────────────────────────────────────────────────────────────────────
-- 2. TRIGGER: Notificar cuando se crea una reserva
-- ──────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION notify_reservation_created()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_group_owner_id UUID;
  v_group_name TEXT;
  v_client_name TEXT;
BEGIN
  -- Obtener owner del grupo
  SELECT owner_id, name INTO v_group_owner_id, v_group_name
  FROM groups WHERE id = NEW.group_id;

  -- Obtener nombre del cliente
  SELECT full_name INTO v_client_name
  FROM profiles WHERE id = NEW.client_id;

  -- Crear notificación para el grupo
  IF v_group_owner_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, type, title, message, reference_id)
    VALUES (
      v_group_owner_id,
      'reservation',
      '🎉 Nueva reserva recibida',
      v_client_name || ' solicitó una reserva para el ' || TO_CHAR(NEW.event_date, 'DD/MM/YYYY') || '.',
      NEW.id
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Activar trigger
DROP TRIGGER IF EXISTS trigger_notify_reservation_created ON reservations;
CREATE TRIGGER trigger_notify_reservation_created
AFTER INSERT ON reservations
FOR EACH ROW
EXECUTE FUNCTION notify_reservation_created();


-- ──────────────────────────────────────────────────────────────────────────────
-- 3. VERIFICAR/ACTUALIZAR ENUM DE STATUS EN RESERVATIONS
-- ──────────────────────────────────────────────────────────────────────────────

-- Si la columna status es un ENUM, agregar 'rejected'
-- Si es TEXT, no se necesita hacer nada

-- Para verificar el tipo de la columna:
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'reservations' AND column_name = 'status';

-- Si el resultado es 'USER-DEFINED', ejecuta esto:
-- (Si es 'text', omite esta parte)

DO $$
BEGIN
  -- Intentar agregar 'rejected' al enum si existe
  BEGIN
    ALTER TYPE reservation_status ADD VALUE IF NOT EXISTS 'rejected';
  EXCEPTION
    WHEN duplicate_object THEN NULL;
    WHEN undefined_object THEN NULL;
  END;
END $$;


-- ──────────────────────────────────────────────────────────────────────────────
-- 4. STORAGE BUCKET: group-images (Para fotos de grupos)
-- ──────────────────────────────────────────────────────────────────────────────

-- IMPORTANTE: Esto NO se puede hacer por SQL, debes hacerlo manualmente:
--
-- 1. Ve a: Supabase Dashboard → Storage
-- 2. Click en "New bucket"
-- 3. Nombre: group-images
-- 4. Public bucket: ✓ SI (activado)
-- 5. Allowed MIME types: image/jpeg, image/png, image/webp
-- 6. File size limit: 5242880 (5 MB)
-- 7. Click "Create bucket"


-- ──────────────────────────────────────────────────────────────────────────────
-- 5. STORAGE BUCKET: group-videos (Para videos promocionales)
-- ──────────────────────────────────────────────────────────────────────────────

-- IMPORTANTE: Esto NO se puede hacer por SQL, debes hacerlo manualmente:
--
-- 1. Ve a: Supabase Dashboard → Storage
-- 2. Click en "New bucket"
-- 3. Nombre: group-videos
-- 4. Public bucket: ✓ SI (activado)
-- 5. Allowed MIME types: video/mp4, video/quicktime, video/webm
-- 6. File size limit: 52428800 (50 MB)
-- 7. Click "Create bucket"


-- ──────────────────────────────────────────────────────────────────────────────
-- 6. VERIFICACIONES FINALES
-- ──────────────────────────────────────────────────────────────────────────────

-- Verificar que la tabla notifications se creó
SELECT COUNT(*) as notifications_table_exists
FROM information_schema.tables
WHERE table_schema = 'public' AND table_name = 'notifications';
-- Debe devolver 1

-- Verificar que las políticas RLS están activas
SELECT COUNT(*) as rls_policies_count
FROM pg_policies
WHERE tablename = 'notifications';
-- Debe devolver 4 (las 4 políticas)

-- Verificar que el trigger se creó
SELECT COUNT(*) as trigger_exists
FROM information_schema.triggers
WHERE trigger_name = 'trigger_notify_reservation_created';
-- Debe devolver 1

-- Ver el tipo de la columna status
SELECT data_type
FROM information_schema.columns
WHERE table_name = 'reservations' AND column_name = 'status';
-- Si devuelve 'text' o 'character varying': ✅ OK, acepta cualquier valor
-- Si devuelve 'USER-DEFINED': Verifica que incluya 'rejected'


-- ══════════════════════════════════════════════════════════════════════════════
-- TESTING: Crear notificación de prueba
-- ══════════════════════════════════════════════════════════════════════════════

-- Reemplaza USER_ID_AQUI con tu UUID de auth.users
-- Puedes obtenerlo con: SELECT id FROM auth.users LIMIT 1;

/*
INSERT INTO notifications (user_id, type, title, message)
VALUES (
  'USER_ID_AQUI',
  'system',
  '🎉 ¡Sistema de notificaciones activo!',
  'Las notificaciones están funcionando correctamente. Este es un mensaje de prueba.'
);
*/


-- ══════════════════════════════════════════════════════════════════════════════
-- ✅ CHECKLIST
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Después de ejecutar este script, verifica:
--
-- [ ] Tabla 'notifications' creada
-- [ ] 4 políticas RLS activas en 'notifications'
-- [ ] Trigger 'trigger_notify_reservation_created' activo
-- [ ] Bucket 'group-images' creado (manual)
-- [ ] Bucket 'group-videos' creado (manual)
-- [ ] Status 'rejected' permitido en reservations
--
-- Si todo está ✓, tu backend está listo.
-- ══════════════════════════════════════════════════════════════════════════════

# 🎯 INSTRUCCIONES PARA CONFIGURAR SUPABASE

## ⚡ PASOS RÁPIDOS

### 1. Abre Supabase Dashboard
Ve a [supabase.com](https://supabase.com) → Tu proyecto → **SQL Editor**

### 2. Ejecuta los archivos EN ESTE ORDEN

```
1. 01_tablas_base.sql        ← Crea todas las tablas
2. 02_triggers_y_funciones.sql ← Automatización (comisión, perfil, rating)
3. 03_rls_policies.sql       ← Seguridad (quién puede ver qué)
4. 04_vistas_materializadas.sql ← Dashboard admin
5. 05_datos_iniciales.sql    ← Países y mensajes motivacionales
```

Para cada archivo:
1. Copia el contenido completo
2. Pégalo en SQL Editor
3. Haz clic en **"Run"**
4. Verifica que aparezca `✅` al final

---

## 👤 CREAR USUARIO ADMIN

1. En Supabase → **Authentication** → **Users** → **Add User**
2. Email: `admin@daricefy.app`
3. Password: elige uno seguro
4. Luego en **SQL Editor** ejecuta:

```sql
UPDATE public.profiles
SET role = 'admin', full_name = 'Administrador Daricefy'
WHERE email = 'admin@daricefy.app';
```

---

## 🎸 CREAR UN GRUPO DE PRUEBA

1. Regístrate en la app como usuario (rol: Músico)
2. En **SQL Editor** ejecuta para asignarle el rol group:

```sql
UPDATE public.profiles
SET role = 'group'
WHERE email = 'tu-email@ejemplo.com';
```

3. Luego inserta el grupo:

```sql
INSERT INTO public.groups (owner_id, name, genre, city, country, country_id, price_from)
SELECT
  p.id,
  'Los Maestros del Son',
  'Banda',
  'Guadalajara',
  'México',
  c.id,
  3500.00
FROM public.profiles p, public.countries c
WHERE p.email = 'tu-email@ejemplo.com'
  AND c.code = 'MXN';
```

---

## 🐛 ARREGLAR BUG DE COMISIÓN EN 0

El bug estaba en que las reservas antiguas no tenían `total_price` o el grupo no tenía `country_id`.

Solución:
1. Asegúrate de que el grupo tenga `country_id` asignado
2. El trigger `set_commission_before_insert` ahora calcula automáticamente la comisión
3. Si hay reservas viejas con comisión en 0, ejecuta:

```sql
UPDATE public.reservations r
SET
  platform_commission = ROUND(r.total_price * COALESCE(
    (SELECT c.commission_rate FROM public.groups g JOIN public.countries c ON g.country_id = c.id WHERE g.id = r.group_id),
    15.0
  ) / 100.0, 2),
  group_earnings = r.total_price - ROUND(r.total_price * COALESCE(
    (SELECT c.commission_rate FROM public.groups g JOIN public.countries c ON g.country_id = c.id WHERE g.id = r.group_id),
    15.0
  ) / 100.0, 2)
WHERE platform_commission = 0 AND total_price > 0;
```

---

## 📦 VARIABLES DE ENTORNO

El archivo `src/config/supabase.ts` ya tiene las credenciales configuradas.

Para producción, créa un archivo `.env`:
```
EXPO_PUBLIC_SUPABASE_URL=https://sqgzyipqpewzbnfrtdqk.supabase.co
EXPO_PUBLIC_SUPABASE_ANON_KEY=tu-anon-key
```

---

## ✅ VERIFICAR QUE TODO FUNCIONA

Ejecuta en SQL Editor:

```sql
-- Ver todas las tablas
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;

-- Ver países cargados
SELECT name, commission_rate, currency_symbol FROM public.countries;

-- Ver mensajes motivacionales
SELECT week_number, message_es FROM public.motivational_messages;
```

---

## 🚀 ARRANCAR LA APP

```bash
cd c:\Users\dann3\Downloads\Miapp
npx expo start
```

Escanea el QR con Expo Go en tu celular, o presiona `a` para Android / `i` para iOS.

---

## 📱 FLUJOS DE PRUEBA

### Como Cliente:
1. Regístrate → rol "Soy Cliente"
2. Explora grupos en Home
3. Selecciona un grupo → Ver paquetes
4. Reserva un paquete
5. Verifica en "Mis Reservas"

### Como Músico (Grupo):
1. Regístrate → rol "Soy Músico"
2. Ve al Dashboard del grupo
3. Crea tus paquetes
4. Solicita verificación
5. Confirma/rechaza reservas de clientes
6. Inicia el temporizador al comenzar un evento

### Como Admin:
1. Inicia sesión con la cuenta admin
2. Ve las estadísticas de la plataforma
3. Gestiona solicitudes de verificación
4. Aprueba/rechaza grupos

-- ============================================================
-- DARICEFY - 00_fix_columnas_existentes.sql
-- ⚠️ CORRER ESTE PRIMERO si ya tenías tablas en Supabase
-- Agrega columnas faltantes a tablas existentes
-- ============================================================

-- ─── PROFILES ───
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS full_name TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS phone TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS phone_verified BOOLEAN DEFAULT FALSE;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS id_verified BOOLEAN DEFAULT FALSE;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();

-- ─── GROUPS ───
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS description TEXT;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS country_id UUID;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS profile_image TEXT;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS promo_video TEXT;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS price_from DECIMAL(10,2);
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS rating DECIMAL(3,2) DEFAULT 4.5;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS total_reviews INTEGER DEFAULT 0;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS members_count INTEGER DEFAULT 1;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS is_verified BOOLEAN DEFAULT FALSE;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS verification_status TEXT DEFAULT 'none';
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE;
ALTER TABLE public.groups ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();

-- ─── PACKAGES ───
ALTER TABLE public.packages ADD COLUMN IF NOT EXISTS duration_hours DECIMAL(4,1) DEFAULT 3.0;
ALTER TABLE public.packages ADD COLUMN IF NOT EXISTS members_count INTEGER;
ALTER TABLE public.packages ADD COLUMN IF NOT EXISTS break_type TEXT DEFAULT 'A';
ALTER TABLE public.packages ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT TRUE;

-- ─── RESERVATIONS ───
ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS event_time TIME;
ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS notes TEXT;
ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS break_type TEXT;
ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS group_arrived_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS arrival_location_lat DECIMAL(10,8);
ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS arrival_location_lng DECIMAL(11,8);
ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS event_started_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS event_ended_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS actual_duration_minutes INTEGER;
ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS qr_code TEXT;
ALTER TABLE public.reservations ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();

-- ─── CREAR TABLAS NUEVAS QUE NO EXISTÍAN ───

CREATE TABLE IF NOT EXISTS public.countries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  code VARCHAR(3) UNIQUE NOT NULL,
  commission_rate DECIMAL(5,2) NOT NULL DEFAULT 15.0,
  currency_code VARCHAR(3) NOT NULL DEFAULT 'MXN',
  currency_symbol VARCHAR(5) NOT NULL DEFAULT '$',
  payment_provider TEXT NOT NULL DEFAULT 'mercadopago',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.extra_hours (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID REFERENCES public.reservations(id) ON DELETE CASCADE,
  hours_added DECIMAL(3,1) NOT NULL,
  price_per_hour DECIMAL(10,2) NOT NULL,
  total_extra_cost DECIMAL(10,2) NOT NULL,
  platform_commission DECIMAL(10,2) NOT NULL,
  group_extra_earnings DECIMAL(10,2) NOT NULL,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending','paid','rejected')),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.event_breaks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID REFERENCES public.reservations(id) ON DELETE CASCADE,
  break_type TEXT NOT NULL,
  scheduled_at TIMESTAMP WITH TIME ZONE,
  started_at TIMESTAMP WITH TIME ZONE,
  ended_at TIMESTAMP WITH TIME ZONE
);

CREATE TABLE IF NOT EXISTS public.verification_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID REFERENCES public.groups(id) ON DELETE CASCADE,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  document_url TEXT,
  admin_notes TEXT,
  submitted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  reviewed_at TIMESTAMP WITH TIME ZONE
);

CREATE TABLE IF NOT EXISTS public.reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID REFERENCES public.reservations(id),
  client_id UUID REFERENCES public.profiles(id),
  group_id UUID REFERENCES public.groups(id),
  rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.motivational_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  week_number INTEGER NOT NULL CHECK (week_number BETWEEN 1 AND 5),
  message_es TEXT NOT NULL,
  category TEXT DEFAULT 'general'
);

CREATE TABLE IF NOT EXISTS public.audio_tracks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID REFERENCES public.groups(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  genre TEXT,
  duration_seconds INTEGER,
  price DECIMAL(10,2) NOT NULL,
  preview_url TEXT,
  full_url TEXT,
  cover_image TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.track_purchases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id UUID REFERENCES public.audio_tracks(id),
  buyer_id UUID REFERENCES public.profiles(id),
  price_paid DECIMAL(10,2) NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.merchandise (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID REFERENCES public.groups(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  price DECIMAL(10,2) NOT NULL,
  stock INTEGER DEFAULT 0,
  images TEXT[],
  sizes TEXT[],
  colors TEXT[],
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.merch_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merch_id UUID REFERENCES public.merchandise(id),
  buyer_id UUID REFERENCES public.profiles(id),
  quantity INTEGER DEFAULT 1,
  size TEXT,
  color TEXT,
  total_price DECIMAL(10,2) NOT NULL,
  status TEXT DEFAULT 'pending',
  shipping_address TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

SELECT 'Columnas y tablas nuevas agregadas correctamente ✅' AS status;

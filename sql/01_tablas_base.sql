-- ============================================================
-- DARICEFY - 01_tablas_base.sql
-- Ejecutar PRIMERO en Supabase SQL Editor
-- ============================================================

-- PAÍSES / COMISIONES
CREATE TABLE IF NOT EXISTS countries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  code VARCHAR(3) UNIQUE NOT NULL,
  commission_rate DECIMAL(5,2) NOT NULL DEFAULT 15.0,
  currency_code VARCHAR(3) NOT NULL DEFAULT 'MXN',
  currency_symbol VARCHAR(5) NOT NULL DEFAULT '$',
  payment_provider TEXT NOT NULL DEFAULT 'mercadopago',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- PERFILES (extende auth.users)
CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT,
  full_name TEXT,
  role TEXT NOT NULL DEFAULT 'client' CHECK (role IN ('admin', 'group', 'client')),
  phone TEXT,
  phone_verified BOOLEAN DEFAULT FALSE,
  id_verified BOOLEAN DEFAULT FALSE,
  avatar_url TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- GRUPOS MUSICALES
CREATE TABLE IF NOT EXISTS groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  genre TEXT,
  description TEXT,
  city TEXT,
  country TEXT,
  country_id UUID REFERENCES countries(id),
  profile_image TEXT,
  promo_video TEXT,
  price_from DECIMAL(10,2),
  rating DECIMAL(3,2) DEFAULT 4.5,
  total_reviews INTEGER DEFAULT 0,
  members_count INTEGER DEFAULT 1,
  is_verified BOOLEAN DEFAULT FALSE,
  verification_status TEXT DEFAULT 'none' CHECK (verification_status IN ('none','pending','approved','rejected')),
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- PAQUETES
CREATE TABLE IF NOT EXISTS packages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  duration_hours DECIMAL(4,1) NOT NULL DEFAULT 3.0,
  price DECIMAL(10,2) NOT NULL,
  members_count INTEGER,
  break_type TEXT DEFAULT 'A' CHECK (break_type IN ('A','B','C','D')),
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  CONSTRAINT min_duration CHECK (duration_hours >= 3.0)
);

-- RESERVACIONES
CREATE TABLE IF NOT EXISTS reservations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID REFERENCES groups(id),
  package_id UUID REFERENCES packages(id),
  client_id UUID REFERENCES profiles(id),
  event_date DATE NOT NULL,
  event_time TIME,
  address TEXT NOT NULL,
  notes TEXT,
  total_price DECIMAL(10,2) NOT NULL,
  platform_commission DECIMAL(10,2) DEFAULT 0,
  group_earnings DECIMAL(10,2) DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','confirmed','in_progress','completed','cancelled')),
  break_type TEXT CHECK (break_type IN ('A','B','C','D')),
  group_arrived_at TIMESTAMP WITH TIME ZONE,
  arrival_location_lat DECIMAL(10,8),
  arrival_location_lng DECIMAL(11,8),
  event_started_at TIMESTAMP WITH TIME ZONE,
  event_ended_at TIMESTAMP WITH TIME ZONE,
  actual_duration_minutes INTEGER,
  qr_code TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- HORAS EXTRA
CREATE TABLE IF NOT EXISTS extra_hours (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID REFERENCES reservations(id) ON DELETE CASCADE,
  hours_added DECIMAL(3,1) NOT NULL,
  price_per_hour DECIMAL(10,2) NOT NULL,
  total_extra_cost DECIMAL(10,2) NOT NULL,
  platform_commission DECIMAL(10,2) NOT NULL,
  group_extra_earnings DECIMAL(10,2) NOT NULL,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending','paid','rejected')),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- DESCANSOS DE EVENTO
CREATE TABLE IF NOT EXISTS event_breaks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID REFERENCES reservations(id) ON DELETE CASCADE,
  break_type TEXT NOT NULL,
  scheduled_at TIMESTAMP WITH TIME ZONE,
  started_at TIMESTAMP WITH TIME ZONE,
  ended_at TIMESTAMP WITH TIME ZONE
);

-- SOLICITUDES DE VERIFICACIÓN
CREATE TABLE IF NOT EXISTS verification_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  document_url TEXT,
  admin_notes TEXT,
  submitted_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  reviewed_at TIMESTAMP WITH TIME ZONE
);

-- RESEÑAS
CREATE TABLE IF NOT EXISTS reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID REFERENCES reservations(id),
  client_id UUID REFERENCES profiles(id),
  group_id UUID REFERENCES groups(id),
  rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- MENSAJES MOTIVACIONALES
CREATE TABLE IF NOT EXISTS motivational_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  week_number INTEGER NOT NULL CHECK (week_number BETWEEN 1 AND 5),
  message_es TEXT NOT NULL,
  category TEXT DEFAULT 'general'
);

-- PISTAS DE AUDIO (marketplace)
CREATE TABLE IF NOT EXISTS audio_tracks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
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

-- COMPRAS DE PISTAS
CREATE TABLE IF NOT EXISTS track_purchases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  track_id UUID REFERENCES audio_tracks(id),
  buyer_id UUID REFERENCES profiles(id),
  price_paid DECIMAL(10,2) NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- MERCHANDISE
CREATE TABLE IF NOT EXISTS merchandise (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
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

-- ÓRDENES DE MERCH
CREATE TABLE IF NOT EXISTS merch_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merch_id UUID REFERENCES merchandise(id),
  buyer_id UUID REFERENCES profiles(id),
  quantity INTEGER DEFAULT 1,
  size TEXT,
  color TEXT,
  total_price DECIMAL(10,2) NOT NULL,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending','processing','shipped','delivered','cancelled')),
  shipping_address TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

SELECT 'Tablas base creadas correctamente ✅' AS status;

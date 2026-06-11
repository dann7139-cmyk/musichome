-- ============================================================
-- DARICEFY - 09_categories.sql
-- Hierarchical category system for providers
-- Run AFTER 08_events_table.sql
-- ============================================================

-- ─────────────────────────────────────────────────
-- 1. CREATE categories TABLE + ensure all columns exist
-- Using ADD COLUMN IF NOT EXISTS so this is safe whether the
-- table was just created or already existed from a previous run.
-- ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.categories (
  id         UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

ALTER TABLE public.categories ADD COLUMN IF NOT EXISTS name      TEXT    NOT NULL DEFAULT '';
ALTER TABLE public.categories ADD COLUMN IF NOT EXISTS parent_id UUID    REFERENCES public.categories(id) ON DELETE SET NULL;
ALTER TABLE public.categories ADD COLUMN IF NOT EXISTS type      TEXT    NOT NULL DEFAULT 'music';
ALTER TABLE public.categories ADD COLUMN IF NOT EXISTS active    BOOLEAN NOT NULL DEFAULT TRUE;

-- Add CHECK on type if it doesn't exist yet
DO $$ BEGIN
  ALTER TABLE public.categories
    ADD CONSTRAINT categories_type_check
    CHECK (type IN ('music', 'entertainment', 'service'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Two partial unique indexes cover both cases:
-- 1. Root categories (no parent): name must be globally unique among roots.
-- 2. Child categories: name must be unique within each parent.
CREATE UNIQUE INDEX IF NOT EXISTS idx_categories_unique_name_root
  ON public.categories (name)
  WHERE parent_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_categories_unique_name_child
  ON public.categories (name, parent_id)
  WHERE parent_id IS NOT NULL;

-- ─────────────────────────────────────────────────
-- 2. CREATE provider_categories RELATION TABLE
-- Same safe pattern: create minimal table, then ADD COLUMN IF NOT EXISTS.
-- ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.provider_categories (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

ALTER TABLE public.provider_categories
  ADD COLUMN IF NOT EXISTS group_id    UUID REFERENCES public.groups(id)     ON DELETE CASCADE;
ALTER TABLE public.provider_categories
  ADD COLUMN IF NOT EXISTS category_id UUID REFERENCES public.categories(id) ON DELETE CASCADE;

-- Unique constraint (safe to re-run)
DO $$ BEGIN
  ALTER TABLE public.provider_categories
    ADD CONSTRAINT provider_categories_group_cat_key UNIQUE (group_id, category_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────────
-- 3. TRIGGER: enforce minimum 1 category per provider
-- Fires BEFORE DELETE; at that moment the row is still counted,
-- so count = 1 means deleting would leave the provider with 0 categories.
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.prevent_last_category_removal()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF (
    SELECT COUNT(*)
    FROM public.provider_categories
    WHERE group_id = OLD.group_id
  ) = 1 THEN
    RAISE EXCEPTION
      'A provider must keep at least one category. Assign a new one before removing this.';
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS enforce_min_one_category ON public.provider_categories;
CREATE TRIGGER enforce_min_one_category
  BEFORE DELETE ON public.provider_categories
  FOR EACH ROW EXECUTE FUNCTION public.prevent_last_category_removal();

-- ─────────────────────────────────────────────────
-- 4. INDEXES
-- ─────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_categories_parent_id      ON public.categories(parent_id);
CREATE INDEX IF NOT EXISTS idx_categories_type           ON public.categories(type);
CREATE INDEX IF NOT EXISTS idx_categories_active         ON public.categories(active);
CREATE INDEX IF NOT EXISTS idx_pcat_group_id             ON public.provider_categories(group_id);
CREATE INDEX IF NOT EXISTS idx_pcat_category_id          ON public.provider_categories(category_id);

-- ─────────────────────────────────────────────────
-- 5. RLS
-- ─────────────────────────────────────────────────
ALTER TABLE public.categories       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_categories ENABLE ROW LEVEL SECURITY;

-- categories: everyone reads active ones; only admin writes
DROP POLICY IF EXISTS "categories_select_active" ON public.categories;
CREATE POLICY "categories_select_active"
  ON public.categories FOR SELECT
  USING (active = TRUE);

DROP POLICY IF EXISTS "categories_admin_all" ON public.categories;
CREATE POLICY "categories_admin_all"
  ON public.categories FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- provider_categories: everyone reads; provider manages their own rows
DROP POLICY IF EXISTS "pcat_select_all" ON public.provider_categories;
CREATE POLICY "pcat_select_all"
  ON public.provider_categories FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "pcat_group_insert" ON public.provider_categories;
CREATE POLICY "pcat_group_insert"
  ON public.provider_categories FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

DROP POLICY IF EXISTS "pcat_group_delete" ON public.provider_categories;
CREATE POLICY "pcat_group_delete"
  ON public.provider_categories FOR DELETE
  USING (
    EXISTS (SELECT 1 FROM public.groups WHERE id = group_id AND owner_id = auth.uid())
  );

DROP POLICY IF EXISTS "pcat_admin_all" ON public.provider_categories;
CREATE POLICY "pcat_admin_all"
  ON public.provider_categories FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );

-- ─────────────────────────────────────────────────
-- 6. RPC: get_groups_by_category
-- Returns group_ids that belong to a category OR any of its children.
-- Recursive CTE walks the full subtree from the given root.
-- ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_groups_by_category(p_category_id UUID)
RETURNS TABLE(group_id UUID)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH RECURSIVE cat_tree AS (
    -- Anchor: the requested category
    SELECT id FROM categories
    WHERE id = p_category_id AND active = TRUE

    UNION ALL

    -- Recursive: all children
    SELECT c.id FROM categories c
    INNER JOIN cat_tree ct ON c.parent_id = ct.id
    WHERE c.active = TRUE
  )
  SELECT DISTINCT pc.group_id
  FROM provider_categories pc
  WHERE pc.category_id IN (SELECT id FROM cat_tree);
$$;

-- ─────────────────────────────────────────────────
-- 7. SEED: root categories (no hardcoded UUIDs — safe to re-run)
-- Uses the partial unique index on (name) WHERE parent_id IS NULL
-- to skip rows that already exist.
-- ─────────────────────────────────────────────────
INSERT INTO public.categories (name, parent_id, type, active) VALUES
  ('Música en vivo',      NULL, 'music',         TRUE),
  ('Entretenimiento',     NULL, 'entertainment', TRUE),
  ('Servicios de evento', NULL, 'service',       TRUE)
ON CONFLICT DO NOTHING;

-- ─── Subcategories: Música en vivo ───────────────
-- Fetches the real parent UUID by name; inserts all children in one shot.
WITH parent AS (
  SELECT id FROM public.categories
  WHERE name = 'Música en vivo' AND parent_id IS NULL
)
INSERT INTO public.categories (name, parent_id, type, active)
SELECT v.name, parent.id, 'music', TRUE
FROM parent,
(VALUES
  ('Versátil'),
  ('Banda'),
  ('Mariachi'),
  ('Norteño'),
  ('Grupero'),
  ('Cumbia'),
  ('Salsa'),
  ('Merengue'),
  ('Bachata'),
  ('Reggaeton'),
  ('Ranchero'),
  ('Corridos'),
  ('Corridos Tumbados'),
  ('Tropical'),
  ('Jazz'),
  ('Blues'),
  ('Rock'),
  ('Pop'),
  ('Balada'),
  ('R&B'),
  ('Hip Hop'),
  ('Electrónica'),
  ('Vallenato'),
  ('Bolero'),
  ('Tango'),
  ('Folklore'),
  ('Son Jarocho'),
  ('Huapango'),
  ('Danzón'),
  ('Trova'),
  ('Gospel'),
  ('Country'),
  ('Marimba')
) AS v(name)
ON CONFLICT DO NOTHING;

-- ─── Subcategories: Entretenimiento ──────────────
WITH parent AS (
  SELECT id FROM public.categories
  WHERE name = 'Entretenimiento' AND parent_id IS NULL
)
INSERT INTO public.categories (name, parent_id, type, active)
SELECT v.name, parent.id, 'entertainment', TRUE
FROM parent,
(VALUES
  ('DJ'),
  ('Animador'),
  ('Comediante'),
  ('Bailarines'),
  ('Mago')
) AS v(name)
ON CONFLICT DO NOTHING;

-- ─── Subcategories: Servicios de evento ──────────
WITH parent AS (
  SELECT id FROM public.categories
  WHERE name = 'Servicios de evento' AND parent_id IS NULL
)
INSERT INTO public.categories (name, parent_id, type, active)
SELECT v.name, parent.id, 'service', TRUE
FROM parent,
(VALUES
  ('Sonido'),
  ('Iluminación'),
  ('Fotografía'),
  ('Video'),
  ('Decoración')
) AS v(name)
ON CONFLICT DO NOTHING;

SELECT 'Sistema de categorías creado correctamente ✅' AS status;

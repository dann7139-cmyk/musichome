-- ============================================================
-- sql/test_seed_review_comments.sql  (SOLO PRUEBAS — no producción)
-- 💬 Comentarios de ejemplo en reseñas, para ver cómo lucen en
--    el perfil del grupo.
--
--  FIX vs. el seed anterior: aquel solo INSERTABA reseñas nuevas
--  con NOT EXISTS, y como tus reservas YA tenían reseña (solo
--  estrellas, sin texto, de pruebas viejas), no agregaba nada.
--  Este script ACTUALIZA las reseñas existentes que no tienen
--  comentario y les pone texto.
--
--  🧹 Para quitarlos antes de lanzar:
--     UPDATE reviews SET comment = NULL
--     WHERE comment LIKE '%[demo]';
-- ============================================================

WITH frases AS (
  SELECT ARRAY[
    '¡Increíbles! Llegaron puntuales y la fiesta se prendió desde la primera canción. Todos mis invitados preguntaron por ellos. [demo]',
    'Muy profesionales, excelente sonido y repertorio variado. Los volvería a contratar sin pensarlo. [demo]',
    'Superaron mis expectativas. El vocalista tiene una voz espectacular y se adaptaron a las canciones que les pedimos. [demo]',
    'Buen ambiente y trato amable. Solo tardaron un poco en montar el equipo, pero el show lo compensó con creces. [demo]',
    'La mejor decisión para el cumpleaños de mi mamá. Tocaron todas las que les pedimos y hasta se quedaron un rato más. [demo]',
    'Excelente presentación, vestuario impecable y mucha energía en el escenario. 100% recomendados. [demo]'
  ] AS c
),
sin_comentario AS (
  SELECT r.id,
         ROW_NUMBER() OVER (ORDER BY r.created_at) AS rn
  FROM reviews r
  JOIN groups g ON g.id = r.group_id
  WHERE (r.comment IS NULL OR btrim(r.comment) = '')
    -- 🎯 Cambia el nombre si quieres otro grupo de pruebas:
    AND g.name ILIKE '%daniel rivera%'
)
UPDATE reviews rv
SET comment = f.c[1 + ((s.rn - 1) % array_length(f.c, 1))]
FROM sin_comentario s, frases f
WHERE rv.id = s.id;

-- ── VERIFICACIÓN ─────────────────────────────────────────────
SELECT rv.rating, LEFT(rv.comment, 60) AS comentario, rv.created_at::date
FROM reviews rv
JOIN groups g ON g.id = rv.group_id
WHERE g.name ILIKE '%daniel rivera%'
ORDER BY rv.created_at DESC;
-- Esperado: tus reseñas ahora con texto (terminan en “[demo]”)

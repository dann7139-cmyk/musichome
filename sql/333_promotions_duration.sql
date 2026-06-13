-- Agrega campo duration_seconds a promotions.
-- Controla cuántos segundos permanece el anuncio en el carousel del explorador.
-- NULL = usar default (video: 25s, imagen: 5s).
ALTER TABLE promotions ADD COLUMN IF NOT EXISTS duration_seconds INTEGER DEFAULT NULL;

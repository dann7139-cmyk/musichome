import { Asset } from 'expo-asset';
import * as FileSystem from 'expo-file-system/legacy';

/**
 * Logo de Daricefy como data URI en base64 — para documentos generados con
 * expo-print (HTML). Un file:// del asset NO se carga de forma confiable en
 * el WebView interno de impresión (por eso el primer intento salía sin
 * logo); el base64 embebido directo en el <img> siempre funciona.
 */
let cachedLogoDataUri: string | null = null;

export async function getLogoDataUri(): Promise<string> {
  if (cachedLogoDataUri) return cachedLogoDataUri;
  try {
    const asset = Asset.fromModule(require('../../assets/images/icon.png'));
    await asset.downloadAsync();
    const uri = asset.localUri ?? asset.uri;
    if (!uri) return '';
    const base64 = await FileSystem.readAsStringAsync(uri, { encoding: FileSystem.EncodingType.Base64 });
    cachedLogoDataUri = `data:image/png;base64,${base64}`;
    return cachedLogoDataUri;
  } catch {
    return '';
  }
}

/** Encabezado con logo + "Daricefy" en negro sólido (sin verde) — mismo
 * bloque para todo documento formal (visas, reportes admin/grupo). */
export function brandHeaderHtml(logoDataUri: string, subtitle: string): string {
  return `
  <div class="header">
    ${logoDataUri ? `<img src="${logoDataUri}" />` : ''}
    <div>
      <div class="brand">Daricefy</div>
      <div class="doc-title">${subtitle}</div>
    </div>
  </div>`;
}

/** CSS del encabezado — se pega dentro del <style> del documento. */
export const BRAND_HEADER_CSS = `
  .header { display: flex; align-items: center; gap: 14px; border-bottom: 3px solid #00C853; padding-bottom: 16px; margin-bottom: 20px; }
  .header img { width: 46px; height: 46px; border-radius: 10px; }
  .brand { font-size: 20px; font-weight: 800; color: #0a0a0a; }
  .doc-title { font-size: 11px; color: #666; margin-top: 2px; }
`;

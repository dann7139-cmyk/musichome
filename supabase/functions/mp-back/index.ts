// ═══════════════════════════════════════════════════════════════════
// mp-back  –  Supabase Edge Function
// Recibe el redirect de MercadoPago tras el pago (back_urls).
// Devuelve una página HTML que cierra el WebBrowser de la app.
// ═══════════════════════════════════════════════════════════════════

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  const url    = new URL(req.url);
  const status = url.searchParams.get('status') ?? 'unknown';
  const adId   = url.searchParams.get('ad_id')  ?? '';

  const isSuccess = status === 'success';
  const isPending = status === 'pending';

  const emoji   = isSuccess ? '✅' : isPending ? '⏳' : '❌';
  const title   = isSuccess ? '¡Pago exitoso!' : isPending ? 'Pago pendiente' : 'Pago no completado';
  const message = isSuccess
    ? 'Tu anuncio será revisado y activado en breve.'
    : isPending
    ? 'Tu pago está siendo procesado. Te avisaremos cuando se confirme.'
    : 'El pago no pudo completarse. Puedes intentarlo de nuevo.';

  const html = `<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${title}</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
      background: #040404;
      color: #fff;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 24px;
      text-align: center;
    }
    .emoji { font-size: 64px; margin-bottom: 24px; }
    h1 { font-size: 24px; font-weight: 700; margin-bottom: 12px; color: ${isSuccess ? '#00E676' : isPending ? '#F59E0B' : '#FF5252'}; }
    p { font-size: 15px; color: #aaa; line-height: 1.5; margin-bottom: 32px; }
    .btn {
      background: ${isSuccess ? '#00E676' : '#333'};
      color: ${isSuccess ? '#000' : '#fff'};
      border: none;
      border-radius: 12px;
      padding: 14px 32px;
      font-size: 16px;
      font-weight: 600;
      cursor: pointer;
    }
  </style>
</head>
<body>
  <div class="emoji">${emoji}</div>
  <h1>${title}</h1>
  <p>${message}</p>
  <button class="btn" onclick="window.close()">Cerrar</button>
  <script>
    // Cierra automáticamente tras 2 segundos en caso de éxito
    ${isSuccess ? 'setTimeout(() => window.close(), 2000);' : ''}
  </script>
</body>
</html>`;

  return new Response(html, {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'text/html; charset=utf-8' },
  });
});

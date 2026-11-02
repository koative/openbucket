import { readFile } from 'node:fs/promises';

// A stable icon URL for other sites (koative.com's product list); the build runs in site/.
export async function GET() {
  return new Response(await readFile('../brand/app-icon/bucketdeck-256.png'), {
    headers: { 'Content-Type': 'image/png' },
  });
}

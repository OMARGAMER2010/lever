using System;
using Ryujinx.Graphics.Gpu.Image;

void Check(bool condition, string name)
{
    if (!condition) throw new Exception(name);
}

Check(!TextureScaleGeometry.SupportsMipLevels(256, 256, 9, .75f), "192 × 192 no admite nueve niveles mipmap");
Check(!TextureScaleGeometry.SupportsMipLevels(256, 256, 9, .5f), "128 × 128 no admite nueve niveles mipmap");
Check(TextureScaleGeometry.SupportsMipLevels(256, 256, 8, .5f), "Una cadena parcial sí permite 50 %");
Check(TextureScaleGeometry.SupportsMipLevels(1280, 720, 1, .5f), "El render principal puede reducirse a 640 × 360");
Check(TextureScaleGeometry.SupportsMipLevels(256, 1024, 9, .25f), "La dimensión mayor conserva los niveles");
Check(TextureScaleGeometry.SupportsMipLevels(256, 256, 9, 1f), "La escala nativa no cambia");
Check(TextureScaleGeometry.SupportsMipLevels(256, 256, 9, 2f), "El escalado superior se conserva");
Console.WriteLine("PASS ScaleCheck — cadenas completas, parciales, render y escala nativa");

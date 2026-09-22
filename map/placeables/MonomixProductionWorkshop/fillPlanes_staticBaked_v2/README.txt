FS25 static baked fillPlanes v2
================================

Почему эта версия отличается от предыдущей:
fillPlaneShader.xml работает с texture arrays (2darray).
Обычные $data/fillPlanes/*_diffuse.dds / normal.dds / height.dds являются
2D-текстурами и не могут быть напрямую назначены его array-слотам.

Поэтому для статических заранее окрашенных I3D:
- игровой diffuse используется как источник и запекается в непрозрачный RGB;
- alpha diffuse запекается в базовый цвет, дыр больше нет;
- height используется при запекании микрорельефа и gloss;
- normal берётся напрямую:
  $data/fillPlanes/hay_normal.dds
  $data/fillPlanes/silage_normal.dds
  $data/fillPlanes/straw_normal.dds
- displacement из присланного набора проверен:
  32x32, постоянное значение 126/127, визуального рельефа не содержит.

В моделях:
- один Shape;
- один обычный непрозрачный material;
- fillPlaneShader не используется;
- UV масштабированы примерно по штатному unitSize = 4 м.

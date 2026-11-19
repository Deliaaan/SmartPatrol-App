# SmartPatrol-App
Proyecto para la materia de 

## Planificación del proyecto en GitHub

El script `scripts/crear-proyecto.sh` crea un GitHub Project vinculado a
`Deliaaan/SmartPatrol-App`, con vistas Kanban y Roadmap, cinco sprints de dos
semanas, hitos, etiquetas, épicas y sus subissues. La fecha indicada es el
primer día del Sprint 1; los demás comienzan cada 14 días. Las prioridades y
estimaciones iniciales son propuestas y pueden ajustarse.

Requisitos: Bash, `gh`, `jq` y Python 3; una sesión de `gh` autenticada con
permisos de escritura sobre el repositorio y de creación de proyectos para
su propietario. Un token clásico necesita los ámbitos `repo` y `project`;
por ejemplo, después de `gh auth login`, ejecute `gh auth refresh -s project`.
La cuenta ejecutora debe poder crear un proyecto bajo el propietario del
repositorio y vincularlo a este.

```bash
bash scripts/crear-proyecto.sh 2026-12-07
```

El script pide confirmación antes de crear recursos y muestra la URL del
proyecto. No es idempotente: si falla o se interrumpe, revise los recursos
creados antes de repetirlo, para evitar duplicados. Puede ser necesario
eliminar o completar manualmente los recursos parciales.

GitHub no expone en la configuración de vistas de la API el campo de
planificación del Roadmap. Tras ejecutar el script, abra esa vista y seleccione
`Sprint` como campo de planificación; compruebe también que Kanban esté
agrupado por `Status`. Las fechas son planificación inicial, no fechas reales
de entrega.

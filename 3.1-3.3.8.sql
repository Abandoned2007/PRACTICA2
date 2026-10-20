
-- Создаем схему, если её нет
CREATE SCHEMA IF NOT EXISTS lib_db;

-- 3.1. ПЕРВИЧНЫЙ КЛЮЧ + SEQUENCE

-- Проверяем: уникален ли "data.general.id"
SELECT "data.general.id", COUNT(*)
FROM lib_db.lib
GROUP BY "data.general.id"
HAVING COUNT(*) > 1;

-- Создаём sequence для суррогатного PK
CREATE SEQUENCE lib_db.lib_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- Добавляем суррогатный столбец id
ALTER TABLE lib_db.lib
    ADD COLUMN id BIGINT;

-- Заполняем id из sequence
UPDATE lib_db.lib
SET id = nextval('lib_db.lib_id_seq');

-- Делаем id обязательным и назначаем PK
ALTER TABLE lib_db.lib
    ALTER COLUMN id SET NOT NULL;

ALTER TABLE lib_db.lib
    ADD CONSTRAINT lib_pkey PRIMARY KEY (id);

-- Привязываем sequence к колонке
ALTER SEQUENCE lib_db.lib_id_seq
    OWNED BY lib_db.lib.id;

-- Автозаполнение id для будущих вставок
ALTER TABLE lib_db.lib
    ALTER COLUMN id SET DEFAULT nextval('lib_db.lib_id_seq');

-- Проверка
SELECT COUNT(*)           AS total,
       COUNT(id)          AS with_id,
       COUNT(DISTINCT id) AS distinct_id
FROM lib_db.lib;


-- 3.2. ОГРАНИЧЕНИЯ NOT NULL И UNIQUE

-- --- NOT NULL ---
-- Проверяем кандидатов
SELECT
    COUNT(*) FILTER (WHERE "data.general.name" IS NULL)                   AS null_name,
    COUNT(*) FILTER (WHERE "data.general.address.fullAddress" IS NULL)    AS null_addr,
    COUNT(*) FILTER (WHERE "data.general.locale.name" IS NULL)            AS null_region
FROM lib_db.lib;

-- NOT NULL: название учреждения обязательно
ALTER TABLE lib_db.lib
    ALTER COLUMN "data.general.name" SET NOT NULL;

-- NOT NULL: полный адрес обязателен
ALTER TABLE lib_db.lib
    ALTER COLUMN "data.general.address.fullAddress" SET NOT NULL;

-- NOT NULL: регион обязателен (после п.3.3.1 там только Вологодская обл.)
ALTER TABLE lib_db.lib
    ALTER COLUMN "data.general.locale.name" SET NOT NULL;

-- --- UNIQUE (вариант по "data.general.id") ---
SELECT COUNT(*)                            AS total,
       COUNT(DISTINCT "data.general.id")   AS distinct_ids
FROM lib_db.lib;

ALTER TABLE lib_db.lib
    ADD CONSTRAINT uq_lib_general_id
    UNIQUE ("data.general.id");

-- Проверка ограничений
SELECT conname, contype
FROM pg_constraint
WHERE conrelid = 'lib_db.lib'::regclass
  AND contype IN ('p', 'u');


-- 3.3.1. УДАЛЕНИЕ ВСЕГО, КРОМЕ ВОЛОГОДСКОЙ ОБЛАСТИ

-- Смотрим, какие регионы есть в данных
SELECT DISTINCT "data.general.locale.name"
FROM lib_db.lib
LIMIT 50;

-- Удаляем всё, что не Вологодская область
DELETE FROM lib_db.lib
WHERE "data.general.locale.name" NOT LIKE '%Вологодская%'
   OR "data.general.locale.name" IS NULL;

-- Проверка
SELECT COUNT(*) FROM lib_db.lib;
SELECT DISTINCT "data.general.locale.name"
FROM lib_db.lib;


-- 3.3.2. POSTGIS + КОЛОНКА geom

-- Удаляем старое расширение, если оно было установлено не туда
DROP EXTENSION IF EXISTS postgis CASCADE;

-- Устанавливаем PostGIS в стандартную схему public
CREATE EXTENSION IF NOT EXISTS postgis SCHEMA lib_db;

-- Указываем базе, где искать функции и типы PostGIS
SET search_path TO public, lib_db;

-- Проверяем версию
SELECT PostGIS_Version();

-- Теперь добавление колонки с типом geometry пройдет успешно
ALTER TABLE lib_db.lib
    ADD COLUMN geom geometry(Point, 4326);

-- 3.3.3 – 3.3.4. ЗАПОЛНЕНИЕ geom ИЗ JSONB

-- Смотрим пример mapPosition
SELECT "data.general.address.mapPosition"
FROM lib_db.lib
WHERE "data.general.address.mapPosition" IS NOT NULL
LIMIT 5;

-- Заполняем geom через ST_GeomFromGeoJSON
UPDATE lib_db.lib
SET geom = ST_GeomFromGeoJSON("data.general.address.mapPosition"::text)
WHERE "data.general.address.mapPosition" IS NOT NULL
  AND "data.general.address.mapPosition"::text <> ''
  AND "data.general.address.mapPosition"::text <> 'null';

-- Проверка: сколько строк получили геометрию
SELECT
    COUNT(*)               AS total,
    COUNT(geom)            AS with_geom,
    COUNT(*) - COUNT(geom) AS without_geom
FROM lib_db.lib;

-- Проверка SRID
SELECT ST_SRID(geom) AS srid, COUNT(*)
FROM lib_db.lib
WHERE geom IS NOT NULL
GROUP BY 1;


-- 3.3.5. ТАБЛИЦА tags

CREATE TABLE lib_db.tags (
    id          BIGSERIAL PRIMARY KEY,
    external_id BIGINT,                          -- исходный id из JSON
    sys_name    VARCHAR(255),                    -- sysName из JSON
    name        VARCHAR(255) NOT NULL UNIQUE,    -- название тега
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    description TEXT
);

SELECT * FROM lib_db.tags;


-- 3.3.6. ЗАПОЛНЕНИЕ tags ИЗ JSONB-МАССИВА

-- Проверяем тип данных в "data.general.tags"
SELECT jsonb_typeof("data.general.tags") AS json_type, COUNT(*)
FROM lib_db.lib
GROUP BY 1;

-- Вставляем уникальные теги
INSERT INTO lib_db.tags (external_id, sys_name, name)
SELECT DISTINCT
       (elem->>'id')::BIGINT,
       elem->>'sysName',
       elem->>'name'
FROM lib_db.lib c
CROSS JOIN LATERAL jsonb_array_elements(c."data.general.tags") AS elem
WHERE c."data.general.tags" IS NOT NULL
  AND jsonb_typeof(c."data.general.tags") = 'array'
  AND elem->>'name' IS NOT NULL
ON CONFLICT (name) DO NOTHING;

-- Проверка
SELECT COUNT(*) AS total_tags FROM lib_db.tags;
SELECT * FROM lib_db.tags ORDER BY id LIMIT 20;


-- 3.3.7. M2M-ТАБЛИЦА

CREATE TABLE lib_db.m2m_lib_tags (
    lib_id BIGINT NOT NULL
        REFERENCES lib_db.lib(id) ON DELETE CASCADE,
    tag_id BIGINT NOT NULL
        REFERENCES lib_db.tags(id) ON DELETE CASCADE,
    PRIMARY KEY (lib_id, tag_id)
);

-- Заполняем связями
INSERT INTO lib_db.m2m_lib_tags (lib_id, tag_id)
SELECT DISTINCT
    c.id,
    t.id
FROM lib_db.lib c
CROSS JOIN LATERAL jsonb_array_elements(c."data.general.tags") AS elem
JOIN lib_db.tags t ON t.name = elem->>'name'
WHERE c."data.general.tags" IS NOT NULL
  AND jsonb_typeof(c."data.general.tags") = 'array'
ON CONFLICT DO NOTHING;

-- Проверка
SELECT COUNT(*) AS total_links
FROM lib_db.m2m_lib_tags;

-- Сколько тегов у каждой библиотеки (топ-20)
SELECT c.id, c."data.general.name", COUNT(m.tag_id) AS tag_count
FROM lib_db.lib c
LEFT JOIN lib_db.m2m_lib_tags m
       ON m.lib_id = c.id
GROUP BY c.id, c."data.general.name"
ORDER BY tag_count DESC
LIMIT 20;


-- 3.3.8. ИНДЕКСЫ НА M2M-ТАБЛИЦЕ

CREATE INDEX idx_m2m_lib_id
    ON lib_db.m2m_lib_tags (lib_id);

CREATE INDEX idx_m2m_tag_id
    ON lib_db.m2m_lib_tags (tag_id);

-- Проверка индексов
SELECT indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'lib_db'
  AND tablename = 'm2m_lib_tags';

-- Дополнительно: GIST-индекс на geom (полезен для пространственных запросов)
CREATE INDEX idx_lib_geom
    ON lib_db.lib
    USING GIST (geom);


-- ФИНАЛЬНАЯ ПРОВЕРКА

-- Список таблиц в схеме
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'lib_db'
ORDER BY table_name;

-- Колонки основной таблицы
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'lib_db'
  AND table_name = 'lib'
ORDER BY ordinal_position;

-- Итоговая статистика
SELECT
    (SELECT COUNT(*) FROM lib_db.lib)                          AS libraries,
    (SELECT COUNT(*) FROM lib_db.lib WHERE geom IS NOT NULL)   AS with_geom,
    (SELECT COUNT(*) FROM lib_db.tags)                         AS tags,
    (SELECT COUNT(*) FROM lib_db.m2m_lib_tags)                 AS links;
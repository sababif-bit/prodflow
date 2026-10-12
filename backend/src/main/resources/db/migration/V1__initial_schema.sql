-- ProdFlow initial schema
-- Design note: parent and child of a BOM line are both "items".
-- The MVP explodes one level only, but this self-referencing model
-- supports multi-level BOMs later without a migration.

CREATE TABLE item (
    id           BIGSERIAL PRIMARY KEY,
    code         VARCHAR(40)    NOT NULL UNIQUE,
    name         VARCHAR(200)   NOT NULL,
    unit         VARCHAR(20)    NOT NULL,
    type         VARCHAR(20)    NOT NULL CHECK (type IN ('MATERIAL', 'PRODUCT')),
    qty_on_hand  NUMERIC(14, 3) NOT NULL DEFAULT 0 CHECK (qty_on_hand >= 0),
    version      BIGINT         NOT NULL DEFAULT 0
);

CREATE TABLE bom_line (
    id              BIGSERIAL PRIMARY KEY,
    parent_item_id  BIGINT         NOT NULL REFERENCES item (id),
    child_item_id   BIGINT         NOT NULL REFERENCES item (id),
    qty_per         NUMERIC(14, 3) NOT NULL CHECK (qty_per > 0),
    CONSTRAINT uq_bom_line UNIQUE (parent_item_id, child_item_id),
    CONSTRAINT ck_bom_no_self_reference CHECK (parent_item_id <> child_item_id)
);

CREATE TABLE production_order (
    id          BIGSERIAL PRIMARY KEY,
    order_no    VARCHAR(30)    NOT NULL UNIQUE,
    item_id     BIGINT         NOT NULL REFERENCES item (id),
    quantity    NUMERIC(14, 3) NOT NULL CHECK (quantity > 0),
    due_date    DATE           NOT NULL,
    status      VARCHAR(20)    NOT NULL
        CHECK (status IN ('CREATED', 'WAITING_MATERIAL', 'RELEASED', 'DONE')),
    created_at  TIMESTAMP      NOT NULL DEFAULT now()
);

CREATE TABLE purchase_request (
    id                   BIGSERIAL PRIMARY KEY,
    item_id              BIGINT         NOT NULL REFERENCES item (id),
    production_order_id  BIGINT         REFERENCES production_order (id),
    quantity             NUMERIC(14, 3) NOT NULL CHECK (quantity > 0),
    status               VARCHAR(20)    NOT NULL
        CHECK (status IN ('OPEN', 'APPROVED', 'RECEIVED')),
    created_at           TIMESTAMP      NOT NULL DEFAULT now()
);

CREATE INDEX ix_bom_line_parent ON bom_line (parent_item_id);
CREATE INDEX ix_production_order_status ON production_order (status);
CREATE INDEX ix_purchase_request_order_item ON purchase_request (production_order_id, item_id);

-- Demo data for the live presentation (only loaded with profile "demo").
-- Scenario: producing 10 x "Machine frame MR-200" needs 40 screws, only 25 in stock
-- -> order waits, purchase request for 15 screws is created.

INSERT INTO item (code, name, unit, type, qty_on_hand) VALUES
    ('MR-200',   'Machine frame MR-200',        'pcs', 'PRODUCT',  0),
    ('SC-M8',    'Hex screw M8x30',             'pcs', 'MATERIAL', 25),
    ('PL-ST3',   'Steel plate 3 mm 400x300',    'pcs', 'MATERIAL', 30),
    ('PR-40',    'Aluminium profile 40x40',     'm',   'MATERIAL', 50),
    ('BR-L60',   'Angle bracket L60',           'pcs', 'MATERIAL', 100);

INSERT INTO bom_line (parent_item_id, child_item_id, qty_per)
SELECT p.id, c.id, x.qty
FROM (VALUES ('SC-M8', 4), ('PL-ST3', 2), ('PR-40', 3.5), ('BR-L60', 8)) AS x(code, qty)
JOIN item c ON c.code = x.code
JOIN item p ON p.code = 'MR-200';

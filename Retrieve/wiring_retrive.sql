WITH
CABLE_CORE_DATA AS (
    SELECT
        c.CABLE_ID,
        c.CABLE_NUM,
        c.CABLE_LENGTH,
        c.CABLE_NOTE,
        c.UNIT_ID,
        c.ENG_PROJ_ID,
        cs.CABLE_SET_ID,
        cs.CABLE_SET_NAME,
        cs.CABLE_SET_SEQ,
        w.WIRE_ID,
        w.WIRE_TAG,
        COALESCE(lconn.WIRE_GRP_LEVEL, rconn.WIRE_GRP_LEVEL) AS SIGNAL_LEVEL,
        ROW_NUMBER() OVER (
            PARTITION BY cs.CABLE_SET_ID
            ORDER BY
                /* First: SPI "level" (blue number in drawings) */
                COALESCE(lconn.WIRE_GRP_LEVEL, rconn.WIRE_GRP_LEVEL, w.SET_LEVEL),
                /* Then: connection sequence within the level (red number in drawings) */
                LEAST(NVL(lconn.GROUP_SEQ, 999999), NVL(rconn.GROUP_SEQ, 999999)),
                GREATEST(NVL(lconn.GROUP_SEQ, 999999), NVL(rconn.GROUP_SEQ, 999999)),
                /* Then: wire tag/number when present (matches loop drawing behavior better than WIRE_ID) */
                CASE
                    WHEN REGEXP_LIKE(TO_CHAR(w.WIRE_TAG), '^[0-9]+$') THEN 0
                    ELSE 1
                END,
                TO_NUMBER(REGEXP_SUBSTR(TO_CHAR(w.WIRE_TAG), '^[0-9]+')),
                TO_CHAR(w.WIRE_TAG),
                /* Final stable tiebreaker */
                w.WIRE_ID
        ) AS WIRE_SEQUENCE,
        wc.WIRE_COLOR_NAME,
        wg.GROUP_NAME AS INSTRUMENT_NAME,
        cmp.CMPNT_ID,
        cmp.CMPNT_SERV,
        cmp.SIGNAL_TYPE_ID,
        cmp.CMPNT_SYS_IO_TYPE_ID,
        cmp.UDT_SUPPORT_ID1,
        cmp.UDT_SUPPORT_ID2,
        cmp.UDT_SUPPORT_ID4,
        cmp.DWG_ID,
        cmp.LOOP_ID,
        cst.CMPNT_SYS_IO_TYPE_NAME,
        ut.NAME AS SYS_TYPE,
        COALESCE(pu_cmp.UNIT_NAME, pu.UNIT_NAME) AS UNIT_NAME,
        u.UOM_CODE,
        lconn.PANEL_ID AS FROM_PANEL_ID,
        lconn.STRIP_ID AS FROM_STRIP_ID,
        lconn.TERM_ID AS FROM_TERM_ID,
        lconn.GROUP_SEQ AS FROM_GROUP_SEQ,
        lconn.TERM_SIDE AS FROM_TERM_SIDE,
        rconn.PANEL_ID AS TO_PANEL_ID,
        rconn.STRIP_ID AS TO_STRIP_ID,
        rconn.TERM_ID AS TO_TERM_ID,
        rconn.GROUP_SEQ AS TO_GROUP_SEQ,
        rconn.TERM_SIDE AS TO_TERM_SIDE,
        c.CABLE_TYPE_ID,
        c.CABLE_COLOR_ID,
        c.CABLE_GLAND_SIDE1_ID
    FROM CABLE c
        JOIN CABLE_SET cs
            ON cs.CABLE_ID = c.CABLE_ID
        JOIN WIRE w
            ON w.CABLE_SET_ID = cs.CABLE_SET_ID
        LEFT JOIN WIRE_TERMINAL lconn
            ON lconn.WIRE_ID = w.WIRE_ID
           AND lconn.CABLE_SIDE = 1
        LEFT JOIN WIRE_TERMINAL rconn
            ON rconn.WIRE_ID = w.WIRE_ID
           AND rconn.CABLE_SIDE = 2
        LEFT JOIN PANEL pnl_from
            ON pnl_from.PANEL_ID = lconn.PANEL_ID
        LEFT JOIN PANEL pnl_to
            ON pnl_to.PANEL_ID = rconn.PANEL_ID
        LEFT JOIN WIRE_GROUP wg
            ON wg.WIRE_GROUP_ID = COALESCE(lconn.WIRE_GROUP_ID, rconn.WIRE_GROUP_ID)
        LEFT JOIN WIRE_COLOR wc
            ON w.WIRE_COLOR_ID = wc.WIRE_COLOR_ID
        LEFT JOIN COMPONENT cmp
            ON cmp.CMPNT_ID = wg.CMPNT_ID
        LEFT JOIN COMPONENT_SYS_IO_TYPE cst
            ON cst.CMPNT_SYS_IO_TYPE_ID = cmp.CMPNT_SYS_IO_TYPE_ID
        LEFT JOIN UDT_SUPPORT1 ut
            ON ut.UDT_SUPPORT_ID = cmp.UDT_SUPPORT_ID1
        LEFT JOIN UNIT_OF_MEASURE u
            ON c.LENGTH_UOM_ID = u.UOM_ID
        LEFT JOIN PLANT_AREA_UNIT pu
            ON c.UNIT_ID = pu.UNIT_ID
        LEFT JOIN PLANT_AREA_UNIT pu_cmp
            ON cmp.UNIT_ID = pu_cmp.UNIT_ID
        LEFT JOIN PLANT_AREA_UNIT pu_from
            ON pnl_from.UNIT_ID = pu_from.UNIT_ID
        LEFT JOIN PLANT_AREA_UNIT pu_to
            ON pnl_to.UNIT_ID = pu_to.UNIT_ID
    WHERE
        c.DEF_FLG IN ('N', 'C')
        AND c.CABLE_NUM <> 'JUMPERS'
        AND (
            :unit_name_like IS NULL
            OR REGEXP_LIKE(pu_cmp.UNIT_NAME, :unit_name_like)
            OR (
                (c.DEF_FLG = 'C' OR c.CABLE_NUM = 'CROSS WIRE')
                AND (REGEXP_LIKE(pu_from.UNIT_NAME, :unit_name_like) OR REGEXP_LIKE(pu_to.UNIT_NAME, :unit_name_like))
            )
        )
        AND (
            c.DEF_FLG = 'C'
            OR c.CABLE_NUM = 'CROSS WIRE'
            OR (TRIM(wg.GROUP_NAME) IS NOT NULL AND TRIM(wg.GROUP_NAME) <> '****')
        )
)
,
APPARATUS_CHILD_PICK AS (
    /* For each parent apparatus (e.g. BAI1), resolve the best child/module apparatus (e.g. BAI1-1).
       Grouped by PARENT_ID only (not panel) because child apparatus rows often have NULL PANEL_ID. */
    SELECT
        a.PARENT_ID,
        MAX(a.APPAR_NAME) KEEP (
            DENSE_RANK FIRST
            ORDER BY NVL(a.APPAR_SEQ, 999999), a.APPAR_ID
        ) AS APPAR_CHILD_NAME
    FROM APPARATUS a
    WHERE NULLIF(a.PARENT_ID, 0) IS NOT NULL
    GROUP BY a.PARENT_ID
)
,
IO_ASSIGN AS (
    SELECT
        COALESCE(NULLIF(cst.MASTER_CMPNT_ID, 0), cst.CMPNT_ID) AS CMPNT_KEY,
        cst.CS_TAG_ID,
        TO_CHAR(cst.CS_TAG_NAME) AS CS_TAG_NAME,
        cst.PANEL_ID,
        cst.STRIP_ID,
        cst.CHANNEL_ID,
        ch.CHANNEL_NAME,
        COALESCE(ap_id.APPAR_NAME, ap_strip.APPAR_NAME) AS APPAR_NAME,
        appar_type.APPAR_TYPE_NAME AS APPAR_MODULE_NAME,
        io_type.CMPNT_SYS_IO_TYPE_NAME AS CARD_IO_TYPE_NAME,
        TO_CHAR(ap_id.APPAR_MODULE) AS CARD_MODULE_NAME,
        rp.RACK_POS_NAME,
        cr.CABINET_RACK_NAME,
        ROW_NUMBER() OVER (
            PARTITION BY COALESCE(NULLIF(cst.MASTER_CMPNT_ID, 0), cst.CMPNT_ID)
            ORDER BY
                CASE
                    WHEN COALESCE(
                        NULLIF(ch.APPAR_ID, 0),
                        NULLIF(ch.PRIMARY_APPAR_ID, 0),
                        NULLIF(ch.SECONDARY_APPAR_ID, 0),
                        NULLIF(ps.APPAR_ID, 0)
                    ) IS NOT NULL THEN 0
                    ELSE 1
                END,
                CASE WHEN COALESCE(ap_id.APPAR_NAME, ap_strip.APPAR_NAME) IS NOT NULL THEN 0 ELSE 1 END,
                CASE WHEN cr.CABINET_RACK_NAME IS NOT NULL THEN 0 ELSE 1 END,
                CASE WHEN rp.RACK_POS_NAME IS NOT NULL THEN 0 ELSE 1 END,
                cst.CS_TAG_ID
        ) AS RN
    FROM CONTROL_SYSTEM_TAG cst
    LEFT JOIN PANEL_STRIP ps
        ON cst.PANEL_ID = ps.PANEL_ID
       AND cst.STRIP_ID = ps.STRIP_ID
    LEFT JOIN CHANNEL ch
        ON COALESCE(cst.CHANNEL_ID, ps.CHANNEL_ID) = ch.CHANNEL_ID
    LEFT JOIN APPARATUS ap_id
        ON COALESCE(
            NULLIF(ch.APPAR_ID, 0),
            NULLIF(ch.PRIMARY_APPAR_ID, 0),
            NULLIF(ch.SECONDARY_APPAR_ID, 0),
            NULLIF(ps.APPAR_ID, 0)
        ) = ap_id.APPAR_ID
    LEFT JOIN APPARATUS ap_strip
        ON (ap_id.APPAR_ID IS NULL OR ap_id.APPAR_ID = 0)
       AND cst.PANEL_ID = ap_strip.PANEL_ID
       AND cst.STRIP_ID = ap_strip.STRIP_ID
    LEFT JOIN APPARATUS_TYPE appar_type
        ON appar_type.APPAR_TYPE_ID = ap_id.APPAR_TYPE_ID
    LEFT JOIN COMPONENT_SYS_IO_TYPE io_type
        ON io_type.CMPNT_SYS_IO_TYPE_ID = ap_id.CMPNT_SYS_IO_TYPE_ID
    LEFT JOIN RACK_POSITION rp
        ON rp.RACK_POS_ID = COALESCE(
            NULLIF(ap_id.RACK_POS_ID, 0),
            NULLIF(ap_id.REMOTE_RACK_POS_ID, 0),
            NULLIF(ap_id.SEC_REMOTE_RACK_POS_ID, 0),
            NULLIF(ap_strip.RACK_POS_ID, 0),
            NULLIF(ap_strip.REMOTE_RACK_POS_ID, 0),
            NULLIF(ap_strip.SEC_REMOTE_RACK_POS_ID, 0)
        )
    LEFT JOIN CABINET_RACK cr
        ON cr.RACK_ID = COALESCE(
            NULLIF(ap_id.RACK_ID, 0),
            NULLIF(ap_id.REMOTE_RACK_ID, 0),
            NULLIF(ap_id.SEC_REMOTE_RACK_ID, 0),
            NULLIF(ap_strip.RACK_ID, 0),
            NULLIF(ap_strip.REMOTE_RACK_ID, 0),
            NULLIF(ap_strip.SEC_REMOTE_RACK_ID, 0),
            NULLIF(ps.RACK_ID, 0),
            NULLIF(ps.SEC_RACK_ID, 0),
            NULLIF(rp.RACK_ID, 0)
        )
)
,
LOOP_DWG_PICK AS (
    /* Some environments populate LOOP.DWG_ID sparsely; LOOP_DRAWING provides the drawing links.
       Pick the most recent row per LOOP_ID when available (CHG_DATE desc), otherwise fall back to DWG_ID. */
    SELECT
        ld.LOOP_ID,
        ld.DWG_ID,
        ROW_NUMBER() OVER (
            PARTITION BY ld.LOOP_ID
            ORDER BY
                ld.CHG_DATE DESC NULLS LAST,
                ld.DWG_ID
        ) AS RN
    FROM LOOP_DRAWING ld
)
,
AGG AS (
    SELECT
        /* =========================
           Keys / grouping
           ========================= */
        core.INSTRUMENT_NAME,
        core.CABLE_ID,
        core.CABLE_SET_ID,

        /* =========================
           Instrument / loop metadata
           ========================= */
        MAX(core.CMPNT_SERV) AS SERVICE_DESCRIPTION,
        MAX(core.CMPNT_SYS_IO_TYPE_NAME) AS IO_TYPE,
        MAX(core.SYS_TYPE) AS SYSTEM,
        MAX(st.SIGNAL_TYPE_NAME) AS SIGNAL_TYPE_NAME,
        MAX(l.LOOP_NAME) AS LOOP_NAME,
        MAX(dwg.DWG_NAME) AS PID_NUMBER,

        /* =========================
           Ordering helpers (drawing alignment)
           ========================= */
        MIN(core.SIGNAL_LEVEL) KEEP (
            DENSE_RANK FIRST
            ORDER BY
                LEAST(NVL(core.FROM_GROUP_SEQ, 999999), NVL(core.TO_GROUP_SEQ, 999999)),
                core.WIRE_SEQUENCE
        ) AS SIGNAL_LEVEL,
        MIN(LEAST(NVL(core.FROM_GROUP_SEQ, 999999), NVL(core.TO_GROUP_SEQ, 999999))) AS SEGMENT_SEQ,
        MIN(GREATEST(NVL(core.FROM_GROUP_SEQ, 999999), NVL(core.TO_GROUP_SEQ, 999999))) AS SEGMENT_SEQ_END,
        MIN(core.WIRE_SEQUENCE) KEEP (
            DENSE_RANK FIRST
            ORDER BY
                LEAST(NVL(core.FROM_GROUP_SEQ, 999999), NVL(core.TO_GROUP_SEQ, 999999)),
                core.WIRE_SEQUENCE
        ) AS FIRST_WIRE_SEQUENCE,
        MIN(core.FROM_TERM_SIDE) KEEP (
            DENSE_RANK FIRST
            ORDER BY
                LEAST(NVL(core.FROM_GROUP_SEQ, 999999), NVL(core.TO_GROUP_SEQ, 999999)),
                core.WIRE_SEQUENCE
        ) AS FROM_TERM_SIDE,
        MIN(core.TO_TERM_SIDE) KEEP (
            DENSE_RANK FIRST
            ORDER BY
                LEAST(NVL(core.FROM_GROUP_SEQ, 999999), NVL(core.TO_GROUP_SEQ, 999999)),
                core.WIRE_SEQUENCE
        ) AS TO_TERM_SIDE,

        /* =========================
           FROM side (field / device end)
           ========================= */
        MAX(TO_CHAR(from_pnl_sc.PANEL_SUB_CATEGORY_NAME)) AS FROM_PANEL_TYPE,
        MAX(TO_CHAR(from_pnl.PANEL_NAME)) AS FROM_PANEL,
        MAX(TO_CHAR(from_rack.CABINET_RACK_NAME)) AS FROM_RACK,
        MAX(TO_CHAR(COALESCE(from_slot_id.RACK_POS_NAME, from_slot_seq.RACK_POS_NAME))) AS FROM_SLOT,
        MAX(TO_CHAR(from_appar.APPAR_NAME)) AS FROM_CARD,
        MAX(TO_CHAR(from_ch.CHANNEL_NAME)) AS FROM_POS,
        MAX(
            CASE
                WHEN TRIM(TO_CHAR(from_appar.APPAR_NAME)) IS NOT NULL AND TRIM(TO_CHAR(from_strip.STRIP_NAME)) IS NOT NULL
                    THEN TO_CHAR(from_appar.APPAR_NAME) || '/' || TO_CHAR(from_strip.STRIP_NAME)
                ELSE TO_CHAR(from_strip.STRIP_NAME)
            END
        ) AS FROM_TERMINAL_STRIP,
        MAX(TO_CHAR(from_ch.CHANNEL_NAME)) AS FROM_CHANNEL,
        MIN(core.FROM_GROUP_SEQ) AS FROM_GROUP_SEQ,
        LISTAGG(TO_CHAR(from_term.TERM_NUM), ', ')
            WITHIN GROUP (
                ORDER BY
                    NVL(core.FROM_GROUP_SEQ, 999999),
                    core.WIRE_SEQUENCE
            ) AS FROM_TERMINALS,
        LISTAGG(
            NVL(core.FROM_GROUP_SEQ, core.WIRE_SEQUENCE)
            || ':' || NVL(TO_CHAR(core.WIRE_COLOR_NAME), '')
            || ':' || TO_CHAR(from_term.TERM_NUM),
            ', '
        ) WITHIN GROUP (
            ORDER BY
                NVL(core.FROM_GROUP_SEQ, 999999),
                core.WIRE_SEQUENCE
        ) AS FROM_CORE_TERMINALS,
        /* Drawing-friendly: core colors only (drawing order) */
        LISTAGG(
            TO_CHAR(core.WIRE_COLOR_NAME),
            ', '
        ) WITHIN GROUP (
            ORDER BY
                NVL(core.FROM_GROUP_SEQ, 999999),
                core.WIRE_SEQUENCE
        ) AS FROM_COLOR_TERMINALS,

        /* =========================
           IO assignment (control system card tree)
           ========================= */
        /* IO assignment (component -> control system tag -> panel strip -> channel -> apparatus -> slot -> rack) */
        MAX(TO_CHAR(ioa.CABINET_RACK_NAME)) AS IO_ASSIGN_RACK,
        MAX(TO_CHAR(ioa.RACK_POS_NAME)) AS IO_ASSIGN_SLOT,
        MAX(TO_CHAR(ioa.APPAR_NAME)) AS IO_ASSIGN_CARD,
        MAX(TO_CHAR(ioa.APPAR_MODULE_NAME)) AS IO_ASSIGN_MODULE,
        MAX(TO_CHAR(ioa.CARD_IO_TYPE_NAME)) AS IO_ASSIGN_CARD_TYPE,
        MAX(TO_CHAR(ioa.CARD_MODULE_NAME)) AS IO_ASSIGN_CARD_MODULE,
        MAX(TO_CHAR(ioa.CHANNEL_NAME)) AS IO_ASSIGN_CHANNEL,
        MAX(TO_CHAR(ioa.CS_TAG_NAME)) AS CS_TAG,

        /* =========================
           Cable properties
           ========================= */
        core.CABLE_NUM AS CABLE_NAME,
        core.CABLE_SET_NAME,
        core.CABLE_SET_SEQ,
        MAX(cable_type.CABLE_TYPE_NAME) AS CABLE_TYPE_NAME,
        MAX(core.CABLE_LENGTH) || ' ' || MAX(core.UOM_CODE) AS ROUTE_LENGTH,
        MAX(cable_gland.CABLE_GLAND_NAME) AS CABLE_GLAND_NAME,

        /* =========================
           TO side (JB / marshalling / PLC/DCS end)
           ========================= */
        MAX(TO_CHAR(to_pnl_sc.PANEL_SUB_CATEGORY_NAME)) AS TO_PANEL_TYPE,
        MAX(TO_CHAR(to_pnl.PANEL_NAME)) AS TO_PANEL,
        MAX(TO_CHAR(to_rack.CABINET_RACK_NAME)) AS TO_RACK,
        MAX(TO_CHAR(COALESCE(to_slot_id.RACK_POS_NAME, to_slot_seq.RACK_POS_NAME))) AS TO_SLOT,
        MAX(TO_CHAR(to_appar.APPAR_NAME)) AS TO_CARD,
        MAX(TO_CHAR(to_ch.CHANNEL_NAME)) AS TO_POS,
        LISTAGG(
            DISTINCT
            CASE
                WHEN TRIM(TO_CHAR(to_appar.APPAR_NAME)) IS NOT NULL AND TRIM(TO_CHAR(to_strip.STRIP_NAME)) IS NOT NULL
                    THEN TO_CHAR(to_appar.APPAR_NAME) || '/' || TO_CHAR(to_strip.STRIP_NAME)
                ELSE TO_CHAR(to_strip.STRIP_NAME)
            END,
            ', '
        ) WITHIN GROUP (ORDER BY to_strip.STRIP_NAME) AS TO_TERMINAL_STRIP,
        MAX(TO_CHAR(to_ch.CHANNEL_NAME)) AS TO_CHANNEL,
        MIN(core.TO_GROUP_SEQ) AS TO_GROUP_SEQ,
        LISTAGG(TO_CHAR(to_term.TERM_NUM), ', ')
            WITHIN GROUP (
                ORDER BY
                    NVL(core.TO_GROUP_SEQ, 999999),
                    core.WIRE_SEQUENCE
            ) AS TO_TERMINALS,
        LISTAGG(
            NVL(core.TO_GROUP_SEQ, core.WIRE_SEQUENCE)
            || ':' || NVL(TO_CHAR(core.WIRE_COLOR_NAME), '')
            || ':' || TO_CHAR(to_term.TERM_NUM),
            ', '
        ) WITHIN GROUP (
            ORDER BY
                NVL(core.TO_GROUP_SEQ, 999999),
                core.WIRE_SEQUENCE
        ) AS TO_CORE_TERMINALS,
        /* Drawing-friendly: core colors only (drawing order) */
        LISTAGG(
            TO_CHAR(core.WIRE_COLOR_NAME),
            ', '
        ) WITHIN GROUP (
            ORDER BY
                NVL(core.TO_GROUP_SEQ, 999999),
                core.WIRE_SEQUENCE
        ) AS TO_COLOR_TERMINALS,

        /* =========================
           Misc
           ========================= */
        MAX(TO_CHAR(loop_dwg.DWG_NAME)) AS LOOP_DWG_NO,
        MAX(core.UNIT_NAME) AS UNIT_NAME
    FROM CABLE_CORE_DATA core
    LEFT JOIN PANEL from_pnl
        ON core.FROM_PANEL_ID = from_pnl.PANEL_ID
    LEFT JOIN PANEL_SUB_CATEGORY from_pnl_sc
        ON from_pnl.PANEL_SUB_CATEGORY = from_pnl_sc.PANEL_SUB_CATEGORY_ID
    LEFT JOIN PANEL_STRIP from_strip
        ON core.FROM_PANEL_ID = from_strip.PANEL_ID
       AND core.FROM_STRIP_ID = from_strip.STRIP_ID
    LEFT JOIN PANEL_STRIP_TERM from_term
        ON core.FROM_PANEL_ID = from_term.PANEL_ID
       AND core.FROM_STRIP_ID = from_term.STRIP_ID
       AND core.FROM_TERM_ID = from_term.TERM_ID
    LEFT JOIN CHANNEL from_ch
        ON from_term.CHANNEL_ID = from_ch.CHANNEL_ID
    LEFT JOIN APPARATUS from_appar
        ON COALESCE(from_ch.APPAR_ID, from_ch.PRIMARY_APPAR_ID, from_ch.SECONDARY_APPAR_ID, from_strip.APPAR_ID) = from_appar.APPAR_ID
    LEFT JOIN PANEL_STRIP from_card_strip
        ON from_appar.PANEL_ID = from_card_strip.PANEL_ID
       AND from_appar.STRIP_ID = from_card_strip.STRIP_ID
    /* Module-level child apparatus (e.g. BAI1-1).
       CHANNEL.PANEL_ID/STRIP_ID identifies the module strip, not the wire terminal strip.
       The wire lands on the BAI1 parent strip, but the channel belongs to the BAI1-1 child strip. */
    LEFT JOIN APPARATUS from_appar_module
        ON from_appar_module.PANEL_ID = from_ch.PANEL_ID
       AND from_appar_module.STRIP_ID = from_ch.STRIP_ID
       AND NULLIF(from_appar_module.PARENT_ID, 0) IS NOT NULL
    LEFT JOIN CABINET_RACK from_rack
        ON COALESCE(from_appar.RACK_ID, from_card_strip.RACK_ID, from_strip.RACK_ID) = from_rack.RACK_ID
    LEFT JOIN RACK_POSITION from_slot_id
        ON from_slot_id.RACK_POS_ID = from_appar.RACK_POS_ID
    LEFT JOIN RACK_POSITION from_slot_seq
        ON from_slot_seq.RACK_ID = from_rack.RACK_ID
       AND from_slot_seq.RACK_POS_SEQ = COALESCE(from_card_strip.POSITION, from_strip.POSITION)

    /* IO assignment join (pre-resolved from CONTROL_SYSTEM_TAG) */
    LEFT JOIN IO_ASSIGN ioa
        ON ioa.CMPNT_KEY = core.CMPNT_ID
       AND ioa.RN = 1
    LEFT JOIN PANEL to_pnl
        ON core.TO_PANEL_ID = to_pnl.PANEL_ID
    LEFT JOIN PANEL_SUB_CATEGORY to_pnl_sc
        ON to_pnl.PANEL_SUB_CATEGORY = to_pnl_sc.PANEL_SUB_CATEGORY_ID
    LEFT JOIN PANEL_STRIP to_strip
        ON core.TO_PANEL_ID = to_strip.PANEL_ID
       AND core.TO_STRIP_ID = to_strip.STRIP_ID
    LEFT JOIN PANEL_STRIP_TERM to_term
        ON core.TO_PANEL_ID = to_term.PANEL_ID
       AND core.TO_STRIP_ID = to_term.STRIP_ID
       AND core.TO_TERM_ID = to_term.TERM_ID
    LEFT JOIN CHANNEL to_ch
        ON to_term.CHANNEL_ID = to_ch.CHANNEL_ID
    LEFT JOIN APPARATUS to_appar
        ON COALESCE(to_ch.APPAR_ID, to_ch.PRIMARY_APPAR_ID, to_ch.SECONDARY_APPAR_ID, to_strip.APPAR_ID) = to_appar.APPAR_ID
    LEFT JOIN PANEL_STRIP to_card_strip
        ON to_appar.PANEL_ID = to_card_strip.PANEL_ID
       AND to_appar.STRIP_ID = to_card_strip.STRIP_ID
    /* Module-level child apparatus (e.g. BAI1-1) — same logic as FROM side. */
    LEFT JOIN APPARATUS to_appar_module
        ON to_appar_module.PANEL_ID = to_ch.PANEL_ID
       AND to_appar_module.STRIP_ID = to_ch.STRIP_ID
       AND NULLIF(to_appar_module.PARENT_ID, 0) IS NOT NULL
    LEFT JOIN CABINET_RACK to_rack
        ON COALESCE(to_appar.RACK_ID, to_card_strip.RACK_ID, to_strip.RACK_ID) = to_rack.RACK_ID
    LEFT JOIN RACK_POSITION to_slot_id
        ON to_slot_id.RACK_POS_ID = to_appar.RACK_POS_ID
    LEFT JOIN RACK_POSITION to_slot_seq
        ON to_slot_seq.RACK_ID = to_rack.RACK_ID
       AND to_slot_seq.RACK_POS_SEQ = COALESCE(to_card_strip.POSITION, to_strip.POSITION)
    LEFT JOIN CABLE_TYPE cable_type
        ON core.CABLE_TYPE_ID = cable_type.CABLE_TYPE_ID
    LEFT JOIN CABLE_COLOR cable_color
        ON core.CABLE_COLOR_ID = cable_color.CABLE_COLOR_ID
    LEFT JOIN CABLE_GLAND cable_gland
        ON core.CABLE_GLAND_SIDE1_ID = cable_gland.CABLE_GLAND_ID
    LEFT JOIN DRAWING dwg
        ON core.DWG_ID = dwg.DWG_ID
    LEFT JOIN LOOP l
        ON core.LOOP_ID = l.LOOP_ID
    LEFT JOIN LOOP_DWG_PICK ldp
        ON l.LOOP_ID = ldp.LOOP_ID
       AND ldp.RN = 1
    LEFT JOIN DRAWING loop_dwg
        ON COALESCE(NULLIF(l.DWG_ID, 0), ldp.DWG_ID) = loop_dwg.DWG_ID
    LEFT JOIN SIGNAL_TYPE st
        ON core.SIGNAL_TYPE_ID = st.SIGNAL_TYPE_ID
    LEFT JOIN UDF_COMPONENT uc
        ON core.CMPNT_ID = uc.CMPNT_ID
    GROUP BY
        core.INSTRUMENT_NAME,
        core.CABLE_ID,
        core.CABLE_SET_ID,
        core.CABLE_NUM,
        core.CABLE_SET_NAME,
        core.CABLE_SET_SEQ,
        core.FROM_PANEL_ID,
        core.FROM_STRIP_ID,
        core.TO_PANEL_ID,
        core.TO_STRIP_ID
)
SELECT
    /* =========================
       Report columns (keep order stable for Excel consumers)
       ========================= */
    LOOP_NAME,
    INSTRUMENT_NAME,
    SERVICE_DESCRIPTION,
    PID_NUMBER,
    IO_TYPE,
    SYSTEM,
    SIGNAL_TYPE_NAME,
    CABLE_TYPE_NAME,
    CABLE_NAME,
    ROUTE_LENGTH,
    CABLE_GLAND_NAME,
    CABLE_ID,
    CABLE_SET_NAME,
    CABLE_SET_ID,
    CABLE_SET_SEQ,
    SIGNAL_LEVEL,
    CASE
        WHEN SWAP_FLG = 1
            THEN TO_PANEL_TYPE
        ELSE FROM_PANEL_TYPE
    END AS FROM_PANEL_TYPE,
    CASE
        WHEN SWAP_FLG = 1
            THEN TO_PANEL
        ELSE FROM_PANEL
    END AS FROM_PANEL,
    CASE
        WHEN SWAP_FLG = 1
            THEN TO_TERMINAL_STRIP
        ELSE FROM_TERMINAL_STRIP
    END AS FROM_TERMINAL_STRIP,
    CASE
        WHEN SWAP_FLG = 1
            THEN TO_POS
        ELSE FROM_POS
    END AS FROM_POS,
    CASE
        WHEN SWAP_FLG = 1
            THEN TO_GROUP_SEQ
        ELSE FROM_GROUP_SEQ
    END AS FROM_GROUP_SEQ,
    CASE
        WHEN SWAP_FLG = 1
            THEN TO_TERMINALS
        ELSE FROM_TERMINALS
    END AS FROM_TERMINALS,
    CASE
        WHEN SWAP_FLG = 1
            THEN TO_COLOR_TERMINALS
        ELSE FROM_COLOR_TERMINALS
    END AS FROM_COLOR_TERMINALS,
    CASE
        WHEN SWAP_FLG = 1
            THEN FROM_PANEL_TYPE
        ELSE TO_PANEL_TYPE
    END AS TO_PANEL_TYPE,
    CASE
        WHEN SWAP_FLG = 1
            THEN FROM_PANEL
        ELSE TO_PANEL
    END AS TO_PANEL,
    CASE
        WHEN SWAP_FLG = 1
            THEN FROM_TERMINAL_STRIP
        ELSE TO_TERMINAL_STRIP
    END AS TO_TERMINAL_STRIP,
    CASE
        WHEN SWAP_FLG = 1
            THEN FROM_POS
        ELSE TO_POS
    END AS TO_POS,
    CASE
        WHEN SWAP_FLG = 1
            THEN FROM_GROUP_SEQ
        ELSE TO_GROUP_SEQ
    END AS TO_GROUP_SEQ,
    CASE
        WHEN SWAP_FLG = 1
            THEN FROM_TERMINALS
        ELSE TO_TERMINALS
    END AS TO_TERMINALS,
    CASE
        WHEN SWAP_FLG = 1
            THEN FROM_COLOR_TERMINALS
        ELSE TO_COLOR_TERMINALS
    END AS TO_COLOR_TERMINALS,
    /* System IO connection fields (prefer IO assignment, otherwise fall back to PLC/DCS side when present). */
    COALESCE(
        IO_ASSIGN_RACK,
        CASE
            WHEN TO_CHAR(TO_PANEL_TYPE) IN ('PLC', 'DCS') THEN TO_RACK
            WHEN TO_CHAR(FROM_PANEL_TYPE) IN ('PLC', 'DCS') THEN FROM_RACK
            ELSE COALESCE(TO_RACK, FROM_RACK)
        END
    ) AS RACK,
    COALESCE(
        IO_ASSIGN_SLOT,
        CASE
            WHEN TO_CHAR(TO_PANEL_TYPE) IN ('PLC', 'DCS') THEN TO_SLOT
            WHEN TO_CHAR(FROM_PANEL_TYPE) IN ('PLC', 'DCS') THEN FROM_SLOT
            ELSE COALESCE(TO_SLOT, FROM_SLOT)
        END
    ) AS SLOT,
    COALESCE(
        IO_ASSIGN_CARD,
        CASE
            WHEN TO_CHAR(TO_PANEL_TYPE) IN ('PLC', 'DCS') THEN TO_CARD
            WHEN TO_CHAR(FROM_PANEL_TYPE) IN ('PLC', 'DCS') THEN FROM_CARD
            ELSE COALESCE(TO_CARD, FROM_CARD)
        END
    ) AS CARD,
    IO_ASSIGN_MODULE AS TU_TYPE,
    IO_ASSIGN_CARD_TYPE AS CARD_TYPE,
    IO_ASSIGN_CARD_MODULE AS IO_MODULE_TYPE,
    COALESCE(
        IO_ASSIGN_CHANNEL,
        CASE
            WHEN TO_CHAR(TO_PANEL_TYPE) IN ('PLC', 'DCS') THEN TO_CHANNEL
            WHEN TO_CHAR(FROM_PANEL_TYPE) IN ('PLC', 'DCS') THEN FROM_CHANNEL
            ELSE COALESCE(TO_CHANNEL, FROM_CHANNEL)
        END
    ) AS CHANNEL,
    CS_TAG,
    LOOP_DWG_NO,
    UNIT_NAME
FROM (
    SELECT
        a.*,
        /* =========================
           CROSS WIRE direction normalization:
           - For CROSS WIRE, `CABLE_SIDE` (1/2) does not reliably match drawing direction.
           - Normalize so the report shows CROSS WIRE as R -> L when `TERM_SIDE` is available.
           - If `TERM_SIDE` is missing, fall back to GROUP_SEQ ordering. */
        CASE
            WHEN TRIM(TO_CHAR(a.CABLE_NAME)) = 'CROSS WIRE'
             AND a.FROM_TERM_SIDE IS NOT NULL
             AND a.TO_TERM_SIDE IS NOT NULL
             AND a.FROM_TERM_SIDE = 'L'
             AND a.TO_TERM_SIDE = 'R'
                THEN 1
            WHEN TRIM(TO_CHAR(a.CABLE_NAME)) = 'CROSS WIRE'
             AND a.FROM_GROUP_SEQ IS NOT NULL
             AND a.TO_GROUP_SEQ IS NOT NULL
             AND a.FROM_GROUP_SEQ > a.TO_GROUP_SEQ
                THEN 1
            ELSE 0
        END AS SWAP_FLG,
        /* =========================
           Ordering helpers (keep shield/drain with the cable-set)
           ========================= */
        /* Some aggregated rows may have NULL SIGNAL_LEVEL (e.g., shield/drain cores).
           For ordering, inherit the cable-set's lowest non-NULL level so those rows stay with the cable. */
        MIN(a.SIGNAL_LEVEL) OVER (
            PARTITION BY
                a.LOOP_NAME,
                a.INSTRUMENT_NAME,
                a.CABLE_ID,
                a.CABLE_SET_ID
        ) AS CABLE_SIGNAL_LEVEL,
        /* For ordering cable-sets in a drawing-like path, use the best (lowest) non-NULL panel-type rank
           across all rows in the cable-set (shield/drain rows may have NULL panel fields). */
        MIN(
            CASE
                WHEN a.FROM_PANEL_TYPE IS NULL THEN NULL
                WHEN TO_CHAR(a.FROM_PANEL_TYPE) = 'Device Panel' THEN 10
                WHEN TO_CHAR(a.FROM_PANEL_TYPE) = 'Junction Box' THEN 20
                WHEN TO_CHAR(a.FROM_PANEL_TYPE) IN ('Marshaling Racks', 'Marshalling Racks') THEN 30
                WHEN TO_CHAR(a.FROM_PANEL_TYPE) = 'PLC' THEN 40
                WHEN TO_CHAR(a.FROM_PANEL_TYPE) = 'DCS' THEN 50
                ELSE 999
            END
        ) OVER (
            PARTITION BY
                a.LOOP_NAME,
                a.INSTRUMENT_NAME,
                a.CABLE_ID,
                a.CABLE_SET_ID
        ) AS CABLE_FROM_PANEL_TYPE_SORT,
        MIN(
            CASE
                WHEN a.TO_PANEL_TYPE IS NULL THEN NULL
                WHEN TO_CHAR(a.TO_PANEL_TYPE) = 'Device Panel' THEN 10
                WHEN TO_CHAR(a.TO_PANEL_TYPE) = 'Junction Box' THEN 20
                WHEN TO_CHAR(a.TO_PANEL_TYPE) IN ('Marshaling Racks', 'Marshalling Racks') THEN 30
                WHEN TO_CHAR(a.TO_PANEL_TYPE) = 'PLC' THEN 40
                WHEN TO_CHAR(a.TO_PANEL_TYPE) = 'DCS' THEN 50
                ELSE 999
            END
        ) OVER (
            PARTITION BY
                a.LOOP_NAME,
                a.INSTRUMENT_NAME,
                a.CABLE_ID,
                a.CABLE_SET_ID
        ) AS CABLE_TO_PANEL_TYPE_SORT
    FROM AGG a
) x
ORDER BY
    UNIT_NAME,
    LOOP_NAME,
    INSTRUMENT_NAME,
    /* =========================
       High-level grouping
       ========================= */
    /* Keep all rows for the same cable-set together by ordering on the cable-set's level first. */
    NVL(CABLE_SIGNAL_LEVEL, 999999),
    /* Then order cable-sets by panel-type path (Field -> JB -> PLC/DCS). */
    NVL(CABLE_FROM_PANEL_TYPE_SORT, 999999),
    NVL(CABLE_TO_PANEL_TYPE_SORT, 999999),
    CABLE_ID,
    CABLE_SET_ID,
    /* =========================
       Within cable-set ordering
       ========================= */
    /* Then order rows within the cable-set by the actual row level (NULLs inherit the cable-set level). */
    NVL(SIGNAL_LEVEL, NVL(CABLE_SIGNAL_LEVEL, 999999)),
    /* Within the same cable-set/level, keep CROSS WIRE after normal cables. */
    CASE
        WHEN CABLE_NAME <> 'CROSS WIRE' THEN 0
        ELSE 1
    END,
    /* Order segments within a level by GROUP_SEQ */
    SEGMENT_SEQ,
    SEGMENT_SEQ_END,
    FIRST_WIRE_SEQUENCE,
    CASE
        WHEN TO_CHAR(FROM_PANEL_TYPE) = 'Device Panel' THEN 10
        WHEN TO_CHAR(FROM_PANEL_TYPE) = 'Junction Box' THEN 20
        WHEN TO_CHAR(FROM_PANEL_TYPE) = 'Marshaling Racks' THEN 30
        WHEN TO_CHAR(FROM_PANEL_TYPE) = 'Marshalling Racks' THEN 30
        WHEN TO_CHAR(FROM_PANEL_TYPE) = 'PLC' THEN 40
        WHEN TO_CHAR(FROM_PANEL_TYPE) = 'DCS' THEN 50
        ELSE 999
    END,
    CASE
        WHEN TO_CHAR(TO_PANEL_TYPE) = 'Device Panel' THEN 10
        WHEN TO_CHAR(TO_PANEL_TYPE) = 'Junction Box' THEN 20
        WHEN TO_CHAR(TO_PANEL_TYPE) = 'Marshaling Racks' THEN 30
        WHEN TO_CHAR(TO_PANEL_TYPE) = 'Marshalling Racks' THEN 30
        WHEN TO_CHAR(TO_PANEL_TYPE) = 'PLC' THEN 40
        WHEN TO_CHAR(TO_PANEL_TYPE) = 'DCS' THEN 50
        ELSE 999
    END,
    TO_PANEL,
    CABLE_SET_SEQ;


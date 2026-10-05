with params as (
    select
        max(snapshot_date) as snapshot_date,
        60 as lookback_days
    from edldb.sc_replenishment_sandbox.EXPIRATION_HEURISTIC_PREDICTION_PO_LOCATION
),

LT as (
    select
        p.product_part_number,
        least(
            case
                when coalesce(ltpv.avg_lead_time_in_business_days,ltnpv.avg_lead_time_in_business_days) = 0 then 14
                else coalesce(ltpv.adj_avg_lead_time,ltnpv.adj_avg_lead_time,14)
            end,
            180
        ) as expected_leadtime
    from (
        select distinct product_key, product_part_number, chewy_pharmacy_part_number, product_company_description
        from chewybi.products_pharmacy
        where product_company_description in ('Chewy','Chewy Pharmacy')
          and product_status in ('Active','Disco')
          and bundle_flag_type = 'Item'
          and product_type = 'Item'
    ) p
    left join (
        select
            ilv.product_part_number,
            round(avg(ilv.vendor_lead_time_business_days),0)::integer as avg_lead_time_in_business_days,
            round(avg(ilv.vendor_lead_time_business_days)/6*2 + avg(ilv.vendor_lead_time_business_days),0)::integer as adj_avg_lead_time
        from chewybi.item_location_vendor ilv
        cross join params prm
        where ilv.snapshot_date = (
            select max(snapshot_date)
            from chewybi.item_location_vendor
            where snapshot_date <= prm.snapshot_date
        )
          and ilv.primary_vendor_flag = 'true'
        group by 1
    ) ltpv on ltpv.product_part_number = p.product_part_number
    left join (
        select
            ilv.product_part_number,
            round(avg(ilv.vendor_lead_time_business_days),0)::integer as avg_lead_time_in_business_days,
            round(avg(ilv.vendor_lead_time_business_days)/6*2 + avg(ilv.vendor_lead_time_business_days),0)::integer as adj_avg_lead_time
        from chewybi.item_location_vendor ilv
        cross join params prm
        where ilv.snapshot_date = (
            select max(snapshot_date)
            from chewybi.item_location_vendor
            where snapshot_date <= prm.snapshot_date
        )
          and ilv.primary_vendor_flag = 'false'
        group by 1
    ) ltnpv on ltnpv.product_part_number = p.product_part_number
),

overages as (
    select
        document_number,
        product_part_number,
        sum(original_quantity) as ordered_qty,
        sum(DOCUMENT_RECEIPT_ITEM_LEDGER_QUANTITY_EACHES) as received_qty,
        greatest(sum(DOCUMENT_RECEIPT_ITEM_LEDGER_QUANTITY_EACHES) - sum(original_quantity),0) as overage_qty
    from chewybi.procurement_document_product_measures
    group by 1,2
),

po_order_dates as (
    select document_number, min(date(document_order_dttm)) as order_date
    from chewybi.procurement_document_product_measures
    group by 1
),

actual_demand_daily as (
    select
        date(o.order_placed_date) as order_date,
        l.location_code as fc,
        p.product_part_number as sku,
        sum(o.order_line_quantity) as demand_units,
        sum(o.order_line_total_price) as demand_dollars
    from chewybi.order_line_measures o
    left join chewybi.locations l
        on l.location_key = o.fulfillment_center_key
    join chewybi.products p
        on p.product_key = o.product_key
    cross join params prm
    where date(o.order_placed_date)
          between dateadd(day,-prm.lookback_days,prm.snapshot_date)
              and dateadd(day,-1,prm.snapshot_date)
      and o.order_line_each_price <> 0
      and o.order_order_line_status not in ('X','J')
      and p.product_company_description = 'Chewy'
    group by 1,2,3
),

actual_demand as (
    select
        d.sku,
        d.fc,
        sum(d.demand_units) / nullif(max(prm.lookback_days),0) as actual_daily_demand_units,
        sum(d.demand_dollars) / nullif(max(prm.lookback_days),0) as actual_daily_demand_dollars
    from actual_demand_daily d
    cross join params prm
    group by 1,2
),

base as (
    select
        exp.snapshot_date,
        exp.fc,
        exp.product_part_number,
        exp.document_number,
        exp.row_num,
        pod.order_date,
        exp.receipt_date,
        case when pod.order_date is not null and exp.receipt_date is not null
             then datediff(day,pod.order_date,exp.receipt_date) end as actual_leadtime,
        LT.expected_leadtime,
        exp.expiration_date,
        exp.received_units,
        exp.cumulative_received_units,
        exp.adj_oh,
        exp.unit_cost,
        abs(coalesce(exp.AGED_RISK_UNITS_NEXT_3MONTHS,0)) as aged_risk_units,
        abs(coalesce(exp.AGED_RISK_DOLLARS_NEXT_3MONTHS,0)) as aged_risk_dollars,
        greatest(coalesce(exp.days_to_aged_unsellable,0),0) as days_to_aged_unsellable,
        exp.daily_avg_outflow_quantity as forecast_daily_demand_units,
        coalesce(ad.actual_daily_demand_units,0) as actual_daily_demand_units,
        coalesce(ad.actual_daily_demand_dollars,0) as actual_daily_demand_dollars,
        greatest(coalesce(p.expirationdays,0) - coalesce(LT.expected_leadtime,0), 0) as expected_shelf_life_days,
        lower(to_varchar(p.product_published_flag)) as product_published_flag,
        p.product_merch_classification1,
        p.product_merch_classification2,
        case when exp.receipt_date is not null and exp.expiration_date is not null
             then datediff(day,exp.receipt_date,exp.expiration_date) end as receipt_shelf_life_days,
        case when exp.receipt_date is not null
                   and exp.expiration_date is not null
                   and greatest(coalesce(p.expirationdays,0) - coalesce(LT.expected_leadtime,0),0) > 0
             then greatest(
                 greatest(coalesce(p.expirationdays,0) - coalesce(LT.expected_leadtime,0),0)
                 - datediff(day,exp.receipt_date,exp.expiration_date),
                 0
             )
        end as missing_shelflife_days,
        case when exp.receipt_date is null then 1 else 0 end as missing_receipt_date_flag,
        case when coalesce(p.expirationdays,0) <= 0 then 1 else 0 end as no_shelf_life_info_flag,
        case when coalesce(exp.daily_avg_outflow_quantity,0) <= 0 and lower(to_varchar(p.product_published_flag)) = 'false' then 1 else 0 end as unpublished_sku_no_forecast_flag,
        case when coalesce(exp.daily_avg_outflow_quantity,0) <= 0 and lower(to_varchar(p.product_published_flag)) = 'true' then 1 else 0 end as published_sku_no_demand_flag,
        coalesce(ov.ordered_qty,0) as ordered_qty,
        coalesce(ov.received_qty,0) as received_qty,
        greatest(coalesce(ov.overage_qty,0),0) as overage_qty,
        exp.source_document_number,
        exp.source_document_receipt_date
    from edldb.sc_replenishment_sandbox.EXPIRATION_HEURISTIC_PREDICTION_PO_LOCATION exp
    cross join params prm
    left join chewybi.products p on exp.product_part_number = p.product_part_number
    left join actual_demand ad on exp.product_part_number = ad.sku and exp.fc = ad.fc
    left join po_order_dates pod on exp.document_number = pod.document_number
    left join LT on exp.product_part_number = LT.product_part_number
    left join overages ov on exp.document_number = ov.document_number and exp.product_part_number = ov.product_part_number
    where exp.snapshot_date = prm.snapshot_date
),

prebucket_rows as (
    select b.*, 'missing receipt date' as prebucket_name
    from base b
    where receipt_date is null

    union all

    select b.*, 'no shelf life information' as prebucket_name
    from base b
    where receipt_date is not null
      and coalesce(expected_shelf_life_days,0) <= 0

    union all

    select b.*, 'Unpublished SKUs bucket' as prebucket_name
    from base b
    where receipt_date is not null
      and coalesce(expected_shelf_life_days,0) > 0
      and coalesce(forecast_daily_demand_units,0) <= 0
      and product_published_flag = 'false'

    union all

    select b.*, 'Published SKUs bucket with no demand' as prebucket_name
    from base b
    where receipt_date is not null
      and coalesce(expected_shelf_life_days,0) > 0
      and coalesce(forecast_daily_demand_units,0) <= 0
      and product_published_flag = 'true'

    union all

    select b.*, 'other' as prebucket_name
    from base b
    where receipt_date is not null
      and coalesce(expected_shelf_life_days,0) > 0
      and coalesce(forecast_daily_demand_units,0) <= 0
      and coalesce(product_published_flag,'') not in ('true','false')
),

base_valid as (
    select *
    from base
    where receipt_date is not null
      and coalesce(expected_shelf_life_days,0) > 0
      and coalesce(forecast_daily_demand_units,0) > 0
),

scenario_inputs as (
    select
        *,
        days_to_aged_unsellable as dta_actual_shelf,
        days_to_aged_unsellable + coalesce(missing_shelflife_days,0) as dta_expected_shelf,
        case when actual_leadtime is not null and expected_leadtime is not null
             then greatest(actual_leadtime - expected_leadtime,0) else 0 end as leadtime_overage_days,
        least(
            expected_shelf_life_days,
            coalesce(receipt_shelf_life_days,0)
            + case when actual_leadtime is not null and expected_leadtime is not null
                   then greatest(actual_leadtime - expected_leadtime,0) else 0 end
        ) as ontime_receipt_shelf_life_days,
        least(
            coalesce(missing_shelflife_days,0),
            case when actual_leadtime is not null and expected_leadtime is not null
                 then greatest(actual_leadtime - expected_leadtime,0) else 0 end
        ) as missing_shelflife_due_to_lt_days,
        greatest(
            coalesce(missing_shelflife_days,0)
            - least(
                coalesce(missing_shelflife_days,0),
                case when actual_leadtime is not null and expected_leadtime is not null
                     then greatest(actual_leadtime - expected_leadtime,0) else 0 end
            ),
            0
        ) as missing_shelflife_not_due_to_lt_days,
        days_to_aged_unsellable
        + least(
            coalesce(missing_shelflife_days,0),
            case when actual_leadtime is not null and expected_leadtime is not null
                 then greatest(actual_leadtime - expected_leadtime,0) else 0 end
        ) as dta_leadtime_fixed_shelf,
        adj_oh / nullif(forecast_daily_demand_units,0) as line_dos_fcst,
        case when coalesce(actual_daily_demand_units,0) > 0
             then adj_oh / actual_daily_demand_units end as line_dos_actual,
        case when coalesce(overage_qty,0) > 0 and coalesce(received_qty,0) > 0
             then least(adj_oh, adj_oh * overage_qty / nullif(received_qty,0))
             else 0 end as remaining_overage_units,
        case when coalesce(missing_shelflife_days,0) > 0
                  and case when actual_leadtime is not null and expected_leadtime is not null
                           then greatest(actual_leadtime - expected_leadtime,0) else 0 end
                      >= coalesce(missing_shelflife_days,0)
             then 1 else 0 end as leadtime_fully_explains_short_shelf_flag
    from base_valid
),

consume_windows as (
    select
        *,
        sum(line_dos_fcst) over (
            partition by fc,product_part_number
            order by row_num
            rows between current row and unbounded following
        ) as days_to_consume_fcst,
        sum(line_dos_actual) over (
            partition by fc,product_part_number
            order by row_num
            rows between current row and unbounded following
        ) as days_to_consume_actual
    from scenario_inputs
),

risk_calc as (
    select
        *,
        days_to_consume_fcst - line_dos_fcst as consume_start_fcst,
        days_to_consume_fcst as consume_end_fcst,
        days_to_consume_actual - line_dos_actual as consume_start_actual,
        days_to_consume_actual as consume_end_actual
    from consume_windows
),

risk_units as (
    select
        *,
        case when coalesce(adj_oh,0) <= 0 then 0
             when coalesce(actual_daily_demand_units,0) <= 0 then adj_oh
             else least(
                 adj_oh,
                 greatest(
                     consume_end_actual - greatest(consume_start_actual,dta_actual_shelf),
                     0
                 ) * actual_daily_demand_units
             ) end as raw_risk_units_actual,
        case when coalesce(adj_oh,0) <= 0 then 0
             when coalesce(actual_daily_demand_units,0) <= 0 then adj_oh
             else least(
                 adj_oh,
                 greatest(
                     consume_end_actual - greatest(consume_start_actual,dta_expected_shelf),
                     0
                 ) * actual_daily_demand_units
             ) end as raw_risk_units_expected_shelf,
        case when coalesce(adj_oh,0) <= 0 then 0
             else least(
                 adj_oh,
                 greatest(
                     consume_end_fcst - greatest(consume_start_fcst,dta_expected_shelf),
                     0
                 ) * forecast_daily_demand_units
             ) end as raw_risk_units_buy_baseline
    from risk_calc
),

raw_candidates as (
    select
        *,
        least(raw_risk_units_buy_baseline,raw_risk_units_expected_shelf) as raw_base_buy_like_units,
        greatest(raw_risk_units_actual - raw_risk_units_expected_shelf,0) as raw_total_shelflife_issue_units
    from risk_units
),

raw_candidates_2 as (
    select
        *,
        case when overage_qty > 0
             then least(raw_base_buy_like_units,remaining_overage_units)
             else 0 end as raw_overage_issue_units,
        case when leadtime_fully_explains_short_shelf_flag = 1
             then raw_total_shelflife_issue_units else 0 end as raw_leadtime_shelflife_issue_units,
        case when coalesce(missing_shelflife_days,0) > 0
                  and leadtime_fully_explains_short_shelf_flag = 0
             then raw_total_shelflife_issue_units else 0 end as raw_nonleadtime_shelflife_issue_units
    from raw_candidates
),

raw_candidates_3 as (
    select
        *,
        greatest(raw_base_buy_like_units - raw_overage_issue_units,0) as raw_buy_issue_units,
        greatest(raw_risk_units_expected_shelf - raw_base_buy_like_units,0) as raw_fcst_issue_units
    from raw_candidates_2
),

waterfall_1 as (
    select
        *,
        case when aged_risk_units > 0
             then least(raw_overage_issue_units,aged_risk_units)
             else 0 end as overage_issue_units
    from raw_candidates_3
),

waterfall_2 as (
    select
        *,
        greatest(aged_risk_units - overage_issue_units,0) as remaining_units_after_overage,
        least(raw_buy_issue_units,greatest(aged_risk_units - overage_issue_units,0)) as buy_issue_units
    from waterfall_1
),

waterfall_3 as (
    select
        *,
        greatest(remaining_units_after_overage - buy_issue_units,0) as remaining_units_after_buy,
        least(raw_fcst_issue_units,greatest(remaining_units_after_overage - buy_issue_units,0)) as fcst_issue_units
    from waterfall_2
),

waterfall_4 as (
    select
        *,
        greatest(remaining_units_after_buy - fcst_issue_units,0) as remaining_units_after_fcst,
        least(raw_leadtime_shelflife_issue_units,greatest(remaining_units_after_buy - fcst_issue_units,0)) as leadtime_shelflife_issue_units
    from waterfall_3
),

waterfall_5 as (
    select
        *,
        greatest(remaining_units_after_fcst - leadtime_shelflife_issue_units,0) as remaining_units_after_leadtime,
        least(raw_nonleadtime_shelflife_issue_units,greatest(remaining_units_after_fcst - leadtime_shelflife_issue_units,0)) as nonleadtime_shelflife_issue_units
    from waterfall_4
),

waterfall_units_final as (
    select
        *,
        greatest(remaining_units_after_leadtime - nonleadtime_shelflife_issue_units,0) as other_issue_units
    from waterfall_5
),

waterfall_dollars as (
    select
        *,
        case when aged_risk_units > 0 then aged_risk_dollars * overage_issue_units / aged_risk_units else 0 end as overage_issue_dollars,
        case when aged_risk_units > 0 then aged_risk_dollars * buy_issue_units / aged_risk_units else 0 end as buy_issue_dollars,
        case when aged_risk_units > 0 then aged_risk_dollars * fcst_issue_units / aged_risk_units else 0 end as fcst_issue_dollars,
        case when aged_risk_units > 0 then aged_risk_dollars * leadtime_shelflife_issue_units / aged_risk_units else 0 end as leadtime_shelflife_issue_dollars,
        case when aged_risk_units > 0 then aged_risk_dollars * nonleadtime_shelflife_issue_units / aged_risk_units else 0 end as nonleadtime_shelflife_issue_dollars
    from waterfall_units_final
),

modeled_final as (
    select
        *,
        greatest(
            aged_risk_dollars
            - overage_issue_dollars
            - buy_issue_dollars
            - fcst_issue_dollars
            - leadtime_shelflife_issue_dollars
            - nonleadtime_shelflife_issue_dollars,
            0
        ) as other_issue_dollars
    from waterfall_dollars
),

modeled_shaped as (
    select
        snapshot_date,fc,product_part_number,document_number,row_num,order_date,receipt_date,expiration_date,
        received_units,cumulative_received_units,adj_oh,unit_cost,
        aged_risk_units,aged_risk_dollars,days_to_aged_unsellable,
        forecast_daily_demand_units,actual_daily_demand_units,actual_daily_demand_dollars,
        product_published_flag,product_merch_classification1,product_merch_classification2,expected_shelf_life_days,receipt_shelf_life_days,missing_shelflife_days,
        expected_leadtime,actual_leadtime,leadtime_overage_days,ontime_receipt_shelf_life_days,
        missing_shelflife_due_to_lt_days,missing_shelflife_not_due_to_lt_days,leadtime_fully_explains_short_shelf_flag,
        ordered_qty,received_qty,overage_qty,remaining_overage_units,
        missing_receipt_date_flag,no_shelf_life_info_flag,unpublished_sku_no_forecast_flag,published_sku_no_demand_flag,
        dta_actual_shelf,dta_expected_shelf,dta_leadtime_fixed_shelf,
        line_dos_fcst,line_dos_actual,days_to_consume_fcst,days_to_consume_actual,
        consume_start_fcst,consume_end_fcst,consume_start_actual,consume_end_actual,
        raw_risk_units_actual as risk_units_actual,
        raw_risk_units_expected_shelf as risk_units_expected_shelf,
        raw_risk_units_buy_baseline as risk_units_buy_baseline,
        raw_overage_issue_units,raw_buy_issue_units,raw_fcst_issue_units,
        raw_leadtime_shelflife_issue_units,raw_nonleadtime_shelflife_issue_units,
        overage_issue_units,buy_issue_units,fcst_issue_units,leadtime_shelflife_issue_units,
        nonleadtime_shelflife_issue_units,other_issue_units,
        overage_issue_dollars,buy_issue_dollars,fcst_issue_dollars,leadtime_shelflife_issue_dollars,
        nonleadtime_shelflife_issue_dollars,other_issue_dollars,
        0::float as missing_receipt_date_issue_units,
        0::float as missing_receipt_date_issue_dollars,
        0::float as no_shelf_life_info_issue_units,
        0::float as no_shelf_life_info_issue_dollars,
        0::float as unpublished_sku_issue_units,
        0::float as unpublished_sku_issue_dollars,
        0::float as published_sku_no_demand_issue_units,
        0::float as published_sku_no_demand_issue_dollars,
        case when overage_issue_units > 0 then 1 else 0 end as overage_issue_flag,
        case when buy_issue_units > 0 then 1 else 0 end as buy_issue_flag,
        case when fcst_issue_units > 0 then 1 else 0 end as fcst_issue_flag,
        case when leadtime_shelflife_issue_units > 0 then 1 else 0 end as leadtime_shelflife_issue_flag,
        case when nonleadtime_shelflife_issue_units > 0 then 1 else 0 end as nonleadtime_shelflife_issue_flag,
        case when other_issue_units > 0 or other_issue_dollars > 0 then 1 else 0 end as other_issue_flag,
        0 as missing_receipt_date_issue_flag,
        0 as no_shelf_life_info_issue_flag,
        0 as unpublished_sku_issue_flag,
        0 as published_sku_no_demand_issue_flag,
        case
            when aged_risk_units = 0 and aged_risk_dollars = 0 then 'no aged risk'
            when overage_issue_dollars > 0 and overage_issue_dollars = greatest(overage_issue_dollars,buy_issue_dollars,fcst_issue_dollars,leadtime_shelflife_issue_dollars,nonleadtime_shelflife_issue_dollars,other_issue_dollars) then 'Receipt Overage'
            when buy_issue_dollars > 0 and buy_issue_dollars = greatest(overage_issue_dollars,buy_issue_dollars,fcst_issue_dollars,leadtime_shelflife_issue_dollars,nonleadtime_shelflife_issue_dollars,other_issue_dollars) then 'Over-Buy'
            when fcst_issue_dollars > 0 and fcst_issue_dollars = greatest(overage_issue_dollars,buy_issue_dollars,fcst_issue_dollars,leadtime_shelflife_issue_dollars,nonleadtime_shelflife_issue_dollars,other_issue_dollars) then 'Less demand than forecast'
            when leadtime_shelflife_issue_dollars > 0 and leadtime_shelflife_issue_dollars = greatest(overage_issue_dollars,buy_issue_dollars,fcst_issue_dollars,leadtime_shelflife_issue_dollars,nonleadtime_shelflife_issue_dollars,other_issue_dollars) then 'Long Lead-Time'
            when nonleadtime_shelflife_issue_dollars > 0 and nonleadtime_shelflife_issue_dollars = greatest(overage_issue_dollars,buy_issue_dollars,fcst_issue_dollars,leadtime_shelflife_issue_dollars,nonleadtime_shelflife_issue_dollars,other_issue_dollars) then 'Less than Expected Shelf-Life'
            else 'Other'
        end as primary_root_cause,
        source_document_number,
        source_document_receipt_date
    from modeled_final
),

prebucket_shaped as (
    select
        snapshot_date,fc,product_part_number,document_number,row_num,order_date,receipt_date,expiration_date,
        received_units,cumulative_received_units,adj_oh,unit_cost,
        aged_risk_units,aged_risk_dollars,days_to_aged_unsellable,
        forecast_daily_demand_units,actual_daily_demand_units,actual_daily_demand_dollars,
        product_published_flag,product_merch_classification1,product_merch_classification2,expected_shelf_life_days,receipt_shelf_life_days,missing_shelflife_days,
        expected_leadtime,actual_leadtime,
        null::float as leadtime_overage_days,
        null::float as ontime_receipt_shelf_life_days,
        null::float as missing_shelflife_due_to_lt_days,
        null::float as missing_shelflife_not_due_to_lt_days,
        0 as leadtime_fully_explains_short_shelf_flag,
        ordered_qty,received_qty,overage_qty,
        0::float as remaining_overage_units,
        missing_receipt_date_flag,no_shelf_life_info_flag,unpublished_sku_no_forecast_flag,published_sku_no_demand_flag,
        days_to_aged_unsellable as dta_actual_shelf,
        days_to_aged_unsellable as dta_expected_shelf,
        days_to_aged_unsellable as dta_leadtime_fixed_shelf,
        null::float as line_dos_fcst,
        null::float as line_dos_actual,
        null::float as days_to_consume_fcst,
        null::float as days_to_consume_actual,
        null::float as consume_start_fcst,
        null::float as consume_end_fcst,
        null::float as consume_start_actual,
        null::float as consume_end_actual,
        null::float as risk_units_actual,
        null::float as risk_units_expected_shelf,
        null::float as risk_units_buy_baseline,
        0::float as raw_overage_issue_units,
        0::float as raw_buy_issue_units,
        0::float as raw_fcst_issue_units,
        0::float as raw_leadtime_shelflife_issue_units,
        0::float as raw_nonleadtime_shelflife_issue_units,
        0::float as overage_issue_units,
        0::float as buy_issue_units,
        0::float as fcst_issue_units,
        0::float as leadtime_shelflife_issue_units,
        0::float as nonleadtime_shelflife_issue_units,
        case when prebucket_name = 'other' then aged_risk_units else 0 end as other_issue_units,
        0::float as overage_issue_dollars,
        0::float as buy_issue_dollars,
        0::float as fcst_issue_dollars,
        0::float as leadtime_shelflife_issue_dollars,
        0::float as nonleadtime_shelflife_issue_dollars,
        case when prebucket_name = 'other' then aged_risk_dollars else 0 end as other_issue_dollars,
        case when prebucket_name = 'missing receipt date' then aged_risk_units else 0 end as missing_receipt_date_issue_units,
        case when prebucket_name = 'missing receipt date' then aged_risk_dollars else 0 end as missing_receipt_date_issue_dollars,
        case when prebucket_name = 'no shelf life information' then aged_risk_units else 0 end as no_shelf_life_info_issue_units,
        case when prebucket_name = 'no shelf life information' then aged_risk_dollars else 0 end as no_shelf_life_info_issue_dollars,
        case when prebucket_name = 'Unpublished SKUs bucket' then aged_risk_units else 0 end as unpublished_sku_issue_units,
        case when prebucket_name = 'Unpublished SKUs bucket' then aged_risk_dollars else 0 end as unpublished_sku_issue_dollars,
        case when prebucket_name = 'Published SKUs bucket with no demand' then aged_risk_units else 0 end as published_sku_no_demand_issue_units,
        case when prebucket_name = 'Published SKUs bucket with no demand' then aged_risk_dollars else 0 end as published_sku_no_demand_issue_dollars,
        0 as overage_issue_flag,
        0 as buy_issue_flag,
        0 as fcst_issue_flag,
        0 as leadtime_shelflife_issue_flag,
        0 as nonleadtime_shelflife_issue_flag,
        case when prebucket_name = 'other' and (aged_risk_units > 0 or aged_risk_dollars > 0) then 1 else 0 end as other_issue_flag,
        case when prebucket_name = 'missing receipt date' and (aged_risk_units > 0 or aged_risk_dollars > 0) then 1 else 0 end as missing_receipt_date_issue_flag,
        case when prebucket_name = 'no shelf life information' and (aged_risk_units > 0 or aged_risk_dollars > 0) then 1 else 0 end as no_shelf_life_info_issue_flag,
        case when prebucket_name = 'Unpublished SKUs bucket' and (aged_risk_units > 0 or aged_risk_dollars > 0) then 1 else 0 end as unpublished_sku_issue_flag,
        case when prebucket_name = 'Published SKUs bucket with no demand' and (aged_risk_units > 0 or aged_risk_dollars > 0) then 1 else 0 end as published_sku_no_demand_issue_flag,
        case
            when aged_risk_units = 0 and aged_risk_dollars = 0 then 'no aged risk'
            when prebucket_name = 'missing receipt date' then 'Unknown - Missing Receipt Date'
            when prebucket_name = 'no shelf life information' then 'Unknown-Missing Shelf-Life'
            when prebucket_name = 'Unpublished SKUs bucket' then 'Unpublished SKUs bucket'
            when prebucket_name = 'Published SKUs bucket with no demand' then 'Unknown - Published SKUs bucket with no demand'
            when prebucket_name = 'other' then 'Other'
            else prebucket_name
        end as primary_root_cause,
        source_document_number,
        source_document_receipt_date
    from prebucket_rows
),

attribution_v1 as (
    select * from modeled_shaped
    union all
    select * from prebucket_shaped
),

p1a_po_sku as (
    select distinct
        source_document_number,
        product_part_number
    from attribution_v1
    where source_document_number is not null
      and product_part_number is not null
),

p1a_sku as (
    select distinct product_part_number
    from attribution_v1
    where product_part_number is not null
),

p1a_po_sku_fc as (
    select distinct
        source_document_number,
        product_part_number,
        fc
    from attribution_v1
    where source_document_number is not null
      and product_part_number is not null
      and fc is not null
),

p1a_po_fc as (
    select distinct
        source_document_number,
        fc
    from p1a_po_sku_fc
),

p1a_receipt_ctx as (
    select distinct
        source_document_number,
        product_part_number,
        source_document_receipt_date
    from attribution_v1
    where source_document_number is not null
      and source_document_receipt_date is not null
),

p1a_pdpm as (
    select
        pdpm.document_number,
        pdpm.product_part_number,
        min(date(pdpm.document_order_dttm)) as order_date
    from p1a_po_sku k
    inner join edldb.chewybi.procurement_document_product_measures pdpm
      on to_varchar(pdpm.document_number) = to_varchar(k.source_document_number)
     and to_varchar(pdpm.product_part_number) = to_varchar(k.product_part_number)
    where pdpm.po_source = 'Socrates'
    group by pdpm.document_number, pdpm.product_part_number
),

p1a_mercury as (
    select
        mer.item_id,
        min(
            coalesce(
                try_to_date(mer.job_run_date),
                date(try_to_timestamp_ntz(mer.job_run_date))
            )
        ) as date_of_shelf_life_add
    from p1a_sku k
    inner join edldb.sc_replenishment_sandbox.int_item_mercury_auto mer
      on to_varchar(mer.item_id) = to_varchar(k.product_part_number)
    where mer.shelf_life is not null
      and mer.shelf_life <> 0
    group by mer.item_id
),

p1a_map as (
    select distinct
        m.oracle_ordernumber,
        m.po_release_run_id,
        m.external_source_system_id,
        m.location_code,
        m.plan_id
    from p1a_po_fc k
    inner join edldb.sc_replenishment_sandbox.socrates_proposal_mercury_po_mapping m
      on to_varchar(m.oracle_ordernumber) = to_varchar(k.source_document_number)
     and to_varchar(m.location_code) = to_varchar(k.fc)
),

p1a_expected as (
    select distinct
        k.source_document_number,
        k.product_part_number,
        k.fc,
        m.po_release_run_id,
        m.plan_id,
        m.external_source_system_id,
        m.location_code
    from p1a_po_sku_fc k
    inner join p1a_map m
      on to_varchar(m.oracle_ordernumber) = to_varchar(k.source_document_number)
     and to_varchar(m.location_code) = to_varchar(k.fc)
),

p1a_proposals as (
    select
        e.source_document_number,
        e.product_part_number,
        e.fc,
        e.po_release_run_id,
        e.plan_id,
        e.external_source_system_id,
        e.location_code,
        max(iff(pr.proposal_runid is not null, 1, 0)) as proposal_matched,
        iff(count(distinct pr.socrates_channel) = 1, min(pr.socrates_channel), null) as socrates_channel
    from p1a_expected e
    left join edldb.sc_replenishment_sandbox.replenishment_inventory_buying_recommended_proposals pr
      on pr.proposal_runid = e.po_release_run_id
     and to_varchar(pr.item_id) = to_varchar(e.product_part_number)
     and equal_null(pr.plan_id, e.plan_id)
     and equal_null(pr.external_source_system_id, e.external_source_system_id)
     and to_varchar(pr.destination_location_code) = to_varchar(e.location_code)
    group by
        e.source_document_number,
        e.product_part_number,
        e.fc,
        e.po_release_run_id,
        e.plan_id,
        e.external_source_system_id,
        e.location_code
),

p1a_matched_item_runtime as (
    select distinct
        product_part_number as item_id,
        po_release_run_id as proposal_runid
    from p1a_proposals
    where proposal_matched = 1
),

p1a_hmld as (
    select
        h.product_part_number,
        h.runtime,
        iff(count(distinct h.high_moq_flag) = 1, min(h.high_moq_flag), null) as high_moq_flag
    from p1a_matched_item_runtime k
    inner join edldb.sc_replenishment_sandbox.int_hmld_sku_list_auto h
      on to_varchar(h.product_part_number) = to_varchar(k.item_id)
     and h.runtime = k.proposal_runid
    group by h.product_part_number, h.runtime
),

p1a_hmld_runtimes as (
    select distinct runtime
    from p1a_hmld
    where runtime is not null
),

-- One runcatalog row per scoped runtime and normalized channel so the
-- required channel predicate can be applied without multiplying rows.
p1a_runcatalog as (
    select
        rc.runtime,
        lower(trim(to_varchar(rc.execution_channel__no_prefix))) as channel_norm,
        iff(count(distinct rc.runtime_date) = 1, min(rc.runtime_date), null) as runtime_date
    from p1a_hmld_runtimes k
    inner join edldb.sc_replenishment_sandbox.scra__int_runcatalog_all_envs rc
      on rc.runtime = k.runtime
    group by
        rc.runtime,
        lower(trim(to_varchar(rc.execution_channel__no_prefix)))
),

p1a_moq_paths as (
    select
        to_varchar(pr.source_document_number) as source_document_number,
        to_varchar(pr.product_part_number) as product_part_number,
        to_varchar(pr.fc) as fc,
        pr.proposal_matched,
        pr.socrates_channel,
        h.high_moq_flag,
        rc.runtime_date,
        iff(rc.runtime is not null, 1, 0) as channel_match
    from p1a_proposals pr
    left join p1a_hmld h
      on to_varchar(h.product_part_number) = to_varchar(pr.product_part_number)
     and h.runtime = pr.po_release_run_id
    left join p1a_runcatalog rc
      on rc.runtime = h.runtime
     and rc.channel_norm = regexp_replace(lower(trim(to_varchar(pr.socrates_channel))), '^channel[.]', '')
),

p1a_high_moq as (
    select
        source_document_number,
        product_part_number,
        fc,
        iff(
            count(*) = 1
            and max(proposal_matched) = 1
            and count(distinct socrates_channel) = 1,
            min(socrates_channel),
            null
        ) as socrates_channel,
        iff(
            count(*) = 1
            and max(proposal_matched) = 1
            and count(distinct high_moq_flag) = 1,
            min(high_moq_flag),
            null
        ) as high_moq_flag,
        iff(
            count(*) = 1
            and max(proposal_matched) = 1
            and count(distinct runtime_date) = 1,
            min(runtime_date),
            null
        ) as runtime_date,
        iff(
            count(*) = 1
            and max(proposal_matched) = 1,
            min(channel_match),
            0
        ) as channel_match
    from p1a_moq_paths
    group by source_document_number, product_part_number, fc
),

p1a_edi as (
    select
        source_document_number,
        product_part_number,
        source_document_receipt_date,
        item_status_code,
        date_created
    from (
        select
            ctx.source_document_number,
            ctx.product_part_number,
            ctx.source_document_receipt_date,
            edi.item_status_code,
            edi.date_created,
            row_number() over (
                partition by
                    ctx.source_document_number,
                    ctx.product_part_number,
                    ctx.source_document_receipt_date
                order by
                    edi.date_created desc,
                    edi.entry_no_ desc nulls last
            ) as rn
        from p1a_receipt_ctx ctx
        inner join edldb.chewybi.edi_xml_document_line_buffer edi
          on to_varchar(edi.document_no_) = to_varchar(ctx.source_document_number)
         and to_varchar(edi.buyer_part_no_) = to_varchar(ctx.product_part_number)
        where edi.edi_document_type = 'SPS855PURCH'
          and edi.item_status_code in ('IR', 'IA')
          and edi.date_created < ctx.source_document_receipt_date
    )
    where rn = 1
),

p1a_joined as (
    select
        a.*,
        pdpm.document_number as socrates_document_number,
        pdpm.order_date as socrates_order_date,
        mer.date_of_shelf_life_add,
        moq.high_moq_flag,
        moq.socrates_channel,
        moq.channel_match,
        -- High-MOQ “at order”: the exact proposal-linked HMLD runtime is valid
        -- on the PO order date or 1-7 days before. Same-calendar-date equality
        -- is not required (Kelsey/Cory).
        iff(moq.runtime_date <= pdpm.order_date, 1, 0) as high_moq_runtime_ok,
        edi.item_status_code as edi_item_status_code,
        edi.date_created as edi_date_created
    from attribution_v1 a
    left join p1a_pdpm pdpm
      on to_varchar(pdpm.document_number) = to_varchar(a.source_document_number)
     and to_varchar(pdpm.product_part_number) = to_varchar(a.product_part_number)
    left join p1a_mercury mer
      on to_varchar(mer.item_id) = to_varchar(a.product_part_number)
    left join p1a_high_moq moq
      on to_varchar(moq.source_document_number) = to_varchar(a.source_document_number)
     and to_varchar(moq.product_part_number) = to_varchar(a.product_part_number)
     and to_varchar(moq.fc) = to_varchar(a.fc)
    left join p1a_edi edi
      on to_varchar(edi.source_document_number) = to_varchar(a.source_document_number)
     and to_varchar(edi.product_part_number) = to_varchar(a.product_part_number)
     and edi.source_document_receipt_date = a.source_document_receipt_date
),

p1a_enriched as (
    select
        * exclude (
            source_document_number,
            source_document_receipt_date,
            socrates_document_number,
            socrates_order_date,
            channel_match,
            high_moq_runtime_ok,
            edi_item_status_code,
            edi_date_created
        ),
        case
            when edi_item_status_code = 'IR' then edi_date_created
        end as edi_reject_date,
        case
            when primary_root_cause = 'Over-Buy'
             and socrates_document_number is not null
            then
                case
                    when date_of_shelf_life_add > socrates_order_date
                        then 'SOCRATES_MISSING_SHELF_LIFE_AT_ORDER'
                    when high_moq_flag = 1
                     and channel_match = 1
                     and high_moq_runtime_ok = 1
                        then 'SOCRATES_HIGH_MOQ_AT_ORDER'
                    when source_document_receipt_date is not null
                     and edi_item_status_code = 'IR'
                        then 'SOCRATES_VENDOR_SHIPPED_CANCELLED_PO'
                    else 'SOCRATES_OTHER'
                end
        end as secondary_root_cause
    from p1a_joined
)

select
    snapshot_date,fc,product_part_number,document_number,row_num,order_date,receipt_date,expiration_date,
    received_units,cumulative_received_units,adj_oh,unit_cost,
    aged_risk_units,aged_risk_dollars,days_to_aged_unsellable,
    forecast_daily_demand_units,actual_daily_demand_units,actual_daily_demand_dollars,
    product_published_flag,product_merch_classification1,product_merch_classification2,expected_shelf_life_days,receipt_shelf_life_days,missing_shelflife_days,
    expected_leadtime,actual_leadtime,leadtime_overage_days,ontime_receipt_shelf_life_days,
    missing_shelflife_due_to_lt_days,missing_shelflife_not_due_to_lt_days,leadtime_fully_explains_short_shelf_flag,
    ordered_qty,received_qty,overage_qty,remaining_overage_units,
    missing_receipt_date_flag,no_shelf_life_info_flag,unpublished_sku_no_forecast_flag,published_sku_no_demand_flag,
    dta_actual_shelf,dta_expected_shelf,dta_leadtime_fixed_shelf,
    line_dos_fcst,line_dos_actual,days_to_consume_fcst,days_to_consume_actual,
    consume_start_fcst,consume_end_fcst,consume_start_actual,consume_end_actual,
    risk_units_actual,risk_units_expected_shelf,risk_units_buy_baseline,
    raw_overage_issue_units,raw_buy_issue_units,raw_fcst_issue_units,
    raw_leadtime_shelflife_issue_units,raw_nonleadtime_shelflife_issue_units,
    overage_issue_units,buy_issue_units,fcst_issue_units,leadtime_shelflife_issue_units,
    nonleadtime_shelflife_issue_units,other_issue_units,
    overage_issue_dollars,buy_issue_dollars,fcst_issue_dollars,leadtime_shelflife_issue_dollars,
    nonleadtime_shelflife_issue_dollars,other_issue_dollars,
    missing_receipt_date_issue_units,missing_receipt_date_issue_dollars,
    no_shelf_life_info_issue_units,no_shelf_life_info_issue_dollars,
    unpublished_sku_issue_units,unpublished_sku_issue_dollars,
    published_sku_no_demand_issue_units,published_sku_no_demand_issue_dollars,
    overage_issue_flag,buy_issue_flag,fcst_issue_flag,leadtime_shelflife_issue_flag,
    nonleadtime_shelflife_issue_flag,other_issue_flag,
    missing_receipt_date_issue_flag,no_shelf_life_info_issue_flag,
    unpublished_sku_issue_flag,published_sku_no_demand_issue_flag,
    primary_root_cause,
    secondary_root_cause,
    date_of_shelf_life_add,
    high_moq_flag,
    socrates_channel,
    edi_reject_date
from p1a_enriched
order by fc,product_part_number,row_num;

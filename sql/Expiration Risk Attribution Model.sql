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
        greatest(coalesce(ov.overage_qty,0),0) as overage_qty
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
            when overage_issue_dollars > 0 and overage_issue_dollars = greatest(overage_issue_dollars,buy_issue_dollars,fcst_issue_dollars,leadtime_shelflife_issue_dollars,nonleadtime_shelflife_issue_dollars,other_issue_dollars) then 'received overage quantity'
            when buy_issue_dollars > 0 and buy_issue_dollars = greatest(overage_issue_dollars,buy_issue_dollars,fcst_issue_dollars,leadtime_shelflife_issue_dollars,nonleadtime_shelflife_issue_dollars,other_issue_dollars) then 'buying more than we could sell through'
            when fcst_issue_dollars > 0 and fcst_issue_dollars = greatest(overage_issue_dollars,buy_issue_dollars,fcst_issue_dollars,leadtime_shelflife_issue_dollars,nonleadtime_shelflife_issue_dollars,other_issue_dollars) then 'less actual demand than forecasted'
            when leadtime_shelflife_issue_dollars > 0 and leadtime_shelflife_issue_dollars = greatest(overage_issue_dollars,buy_issue_dollars,fcst_issue_dollars,leadtime_shelflife_issue_dollars,nonleadtime_shelflife_issue_dollars,other_issue_dollars) then 'less remaining shelf life due to leadtime'
            when nonleadtime_shelflife_issue_dollars > 0 and nonleadtime_shelflife_issue_dollars = greatest(overage_issue_dollars,buy_issue_dollars,fcst_issue_dollars,leadtime_shelflife_issue_dollars,nonleadtime_shelflife_issue_dollars,other_issue_dollars) then 'less remaining shelf life not explained by leadtime'
            else 'other'
        end as primary_root_cause
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
        case when aged_risk_units = 0 and aged_risk_dollars = 0 then 'no aged risk' else prebucket_name end as primary_root_cause
    from prebucket_rows
)

select * from modeled_shaped
union all
select * from prebucket_shaped
order by fc,product_part_number,row_num;

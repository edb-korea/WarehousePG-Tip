-- ================================================================
-- Greenplum PL/R 종합 테스트 스크립트 (그래픽/X11 렌더링 제외)
-- 대상: t-test, 선형회귀, dplyr, MCMCpack, lme4,
--       ggplot2(비그래픽 검증), randomForest, MatrixModels, SparseM, coda
--
-- 사전 설치 필요 (모든 세그먼트 호스트):
--   R -e 'install.packages(c("MCMCpack","lme4","ggplot2","randomForest",
--                            "MatrixModels","SparseM","coda","dplyr"))'
-- ================================================================

CREATE EXTENSION IF NOT EXISTS plr;

CREATE OR REPLACE FUNCTION plr_packages_check_table()
RETURNS TABLE(package_name text, is_installed boolean) AS $$
    pkgs <- c("MCMCpack","lme4","ggplot2","randomForest",
              "MatrixModels","SparseM","coda","dplyr")
    installed <- sapply(pkgs, function(p) requireNamespace(p, quietly = TRUE))
    return(data.frame(package_name = pkgs, is_installed = installed))
$$ LANGUAGE plr;

-- SELECT * FROM plr_packages_check_table();


-- ================================================================
-- 1. t-test — 두 그룹 평균 비교
-- ================================================================

DROP TABLE IF EXISTS ds_ttest_data;
CREATE TABLE ds_ttest_data (
    id     SERIAL,
    grp    TEXT,      -- 'control' / 'treatment'
    value  NUMERIC
) DISTRIBUTED BY (id);

INSERT INTO ds_ttest_data (grp, value)
SELECT 'control', 50 + (random()*10 - 5) FROM generate_series(1, 100);
INSERT INTO ds_ttest_data (grp, value)
SELECT 'treatment', 55 + (random()*10 - 5) FROM generate_series(1, 100);   -- 평균이 약 5 높게 설계

CREATE OR REPLACE FUNCTION plr_ttest(group_a float8[], group_b float8[])
RETURNS TABLE(mean_a float8, mean_b float8, t_statistic float8,
              p_value float8, ci_lower float8, ci_upper float8) AS $$
    res <- t.test(group_a, group_b)
    return(data.frame(
        mean_a      = mean(group_a),
        mean_b      = mean(group_b),
        t_statistic = res$statistic,
        p_value     = res$p.value,
        ci_lower    = res$conf.int[1],
        ci_upper    = res$conf.int[2]
    ))
$$ LANGUAGE plr;

-- 실행
SELECT * FROM plr_ttest(
    (SELECT array_agg(value) FROM ds_ttest_data WHERE grp = 'control'),
    (SELECT array_agg(value) FROM ds_ttest_data WHERE grp = 'treatment')
);
-- 기대: p_value < 0.05 이면 두 그룹 평균이 통계적으로 유의하게 다름


-- ================================================================
-- 2. 선형 회귀 (Linear Regression)
-- ================================================================

DROP TABLE IF EXISTS ds_regression_data;
CREATE TABLE ds_regression_data (
    id       SERIAL,
    ad_spend NUMERIC,
    sales    NUMERIC
) DISTRIBUTED BY (id);

INSERT INTO ds_regression_data (ad_spend, sales)
SELECT x AS ad_spend, 5 + 2.3 * x + (random() * 10 - 5) AS sales
FROM generate_series(1, 200) AS x;

CREATE OR REPLACE FUNCTION plr_linear_regression(x float8[], y float8[])
RETURNS TABLE(intercept float8, slope float8, r_squared float8, p_value_slope float8) AS $$
    model <- lm(y ~ x)
    s <- summary(model)
    return(data.frame(
        intercept     = coef(model)[1],
        slope         = coef(model)[2],
        r_squared     = s$r.squared,
        p_value_slope = coef(s)[2, 4]
    ))
$$ LANGUAGE plr;

-- 실행
SELECT * FROM plr_linear_regression(
    (SELECT array_agg(ad_spend ORDER BY id) FROM ds_regression_data),
    (SELECT array_agg(sales    ORDER BY id) FROM ds_regression_data)
);
-- 기대: intercept≈5, slope≈2.3


-- ================================================================
-- 3. dplyr — 판매 데이터 그룹 집계 파이프라인
-- ================================================================

DROP TABLE IF EXISTS ds_sales_data;
CREATE TABLE ds_sales_data (
    id       SERIAL,
    region   TEXT,
    product  TEXT,
    quantity INTEGER,
    price    NUMERIC
) DISTRIBUTED BY (id);

INSERT INTO ds_sales_data (region, product, quantity, price)
SELECT
    (ARRAY['서울','부산','대구','인천'])[(random()*3)::int + 1],
    (ARRAY['제품A','제품B','제품C'])[(random()*2)::int + 1],
    (random()*20 + 1)::int,
    round((random()*200 + 50)::numeric, 2)
FROM generate_series(1, 500);

CREATE OR REPLACE FUNCTION process_sales_with_dplyr(
    regions text[], products text[], quantities float8[], prices float8[]
)
RETURNS TABLE(region text, avg_total_sale float8, total_quantity float8) AS $$
    library(dplyr)

    sales_df <- data.frame(
        region   = regions,
        product  = products,
        quantity = quantities,
        price    = prices
    )

    result_df <- sales_df %>%
        mutate(total_sale = quantity * price) %>%   # 총 판매액 열 추가
        group_by(region) %>%                         # 지역별 그룹화
        summarise(
            avg_total_sale = mean(total_sale),
            total_quantity = sum(quantity),
            .groups = "drop"
        ) %>%
        arrange(desc(avg_total_sale))                # 결과 정렬

    return(as.data.frame(result_df))
$$ LANGUAGE plr;

-- 실행
SELECT * FROM process_sales_with_dplyr(
    (SELECT array_agg(region ORDER BY id)   FROM ds_sales_data),
    (SELECT array_agg(product ORDER BY id)  FROM ds_sales_data),
    (SELECT array_agg(quantity ORDER BY id) FROM ds_sales_data),
    (SELECT array_agg(price ORDER BY id)    FROM ds_sales_data)
);


-- ================================================================
-- 4. MCMCpack — 베이지안 선형 회귀
-- ================================================================

DROP TABLE IF EXISTS ds_bayes_data;
CREATE TABLE ds_bayes_data (
    id SERIAL,
    x  NUMERIC,
    y  NUMERIC
) DISTRIBUTED BY (id);

INSERT INTO ds_bayes_data (x, y)
SELECT i AS x, 3 + 1.5 * i + (random()*4 - 2) AS y
FROM generate_series(1, 100) AS i;

CREATE OR REPLACE FUNCTION plr_mcmc_regression(x float8[], y float8[], n_iter integer)
RETURNS TABLE(param text, post_mean float8, post_sd float8,
              ci_2_5 float8, ci_97_5 float8) AS $$
    library(MCMCpack)
    df <- data.frame(x = x, y = y)
    set.seed(1)
    post <- MCMCregress(y ~ x, data = df, mcmc = n_iter, burnin = 1000, verbose = 0)
    s <- summary(post)
    stat <- s$statistics
    q    <- s$quantiles
    return(data.frame(
        param     = rownames(stat)[1:2],
        post_mean = stat[1:2, "Mean"],
        post_sd   = stat[1:2, "SD"],
        ci_2_5    = q[1:2, "2.5%"],
        ci_97_5   = q[1:2, "97.5%"]
    ))
$$ LANGUAGE plr;

-- 실행
SELECT * FROM plr_mcmc_regression(
    (SELECT array_agg(x ORDER BY id) FROM ds_bayes_data),
    (SELECT array_agg(y ORDER BY id) FROM ds_bayes_data),
    5000
);

-- coda 진단용 원시 체인 추출 함수 (섹션 10에서 재사용)
CREATE OR REPLACE FUNCTION plr_mcmc_draws(x float8[], y float8[], n_iter integer)
RETURNS float8[] AS $$
    library(MCMCpack)
    df <- data.frame(x = x, y = y)
    set.seed(1)
    post <- MCMCregress(y ~ x, data = df, mcmc = n_iter, burnin = 1000, verbose = 0)
    return(as.numeric(post[, "x"]))
$$ LANGUAGE plr;


-- ================================================================
-- 5. lme4 — 혼합효과 모델 (그룹별 임의절편)
-- ================================================================

DROP TABLE IF EXISTS ds_mixed_data;
CREATE TABLE ds_mixed_data (
    id     SERIAL,
    school INTEGER,
    hours  NUMERIC,
    score  NUMERIC
) DISTRIBUTED BY (id);

INSERT INTO ds_mixed_data (school, hours, score)
SELECT s AS school, h AS hours,
       (50 + s * 4) + 3 * h + (random() * 6 - 3) AS score
FROM generate_series(1, 5) AS s
CROSS JOIN generate_series(1, 20) AS h;

CREATE OR REPLACE FUNCTION plr_lmer_test(grp integer[], x float8[], y float8[])
RETURNS TABLE(fixed_intercept float8, fixed_slope float8,
              group_variance float8, residual_variance float8) AS $$
    library(lme4)
    df <- data.frame(grp = factor(grp), x = x, y = y)
    model <- lmer(y ~ x + (1 | grp), data = df)
    fe <- fixef(model)
    vc <- as.data.frame(VarCorr(model))
    return(data.frame(
        fixed_intercept   = fe[1],
        fixed_slope       = fe[2],
        group_variance    = vc$vcov[vc$grp == "grp"],
        residual_variance = vc$vcov[vc$grp == "Residual"]
    ))
$$ LANGUAGE plr;

-- 실행
SELECT * FROM plr_lmer_test(
    (SELECT array_agg(school ORDER BY id) FROM ds_mixed_data),
    (SELECT array_agg(hours  ORDER BY id) FROM ds_mixed_data),
    (SELECT array_agg(score  ORDER BY id) FROM ds_mixed_data)
);


-- ================================================================
-- 6. randomForest — 분류 모델 (3개 클래스)
-- ================================================================

DROP TABLE IF EXISTS ds_rf_data;
CREATE TABLE ds_rf_data (
    id    SERIAL,
    feat1 NUMERIC,
    feat2 NUMERIC,
    label TEXT
) DISTRIBUTED BY (id);

INSERT INTO ds_rf_data (feat1, feat2, label)
SELECT 2 + random()*2, 2 + random()*2, 'A' FROM generate_series(1, 60);
INSERT INTO ds_rf_data (feat1, feat2, label)
SELECT 8 + random()*2, 8 + random()*2, 'B' FROM generate_series(1, 60);
INSERT INTO ds_rf_data (feat1, feat2, label)
SELECT 2 + random()*2, 8 + random()*2, 'C' FROM generate_series(1, 60);

CREATE OR REPLACE FUNCTION plr_randomforest_train(f1 float8[], f2 float8[], lbl text[])
RETURNS TABLE(oob_error_rate float8, ntree integer, most_important_feature text) AS $$
    library(randomForest)
    df <- data.frame(feat1 = f1, feat2 = f2, label = factor(lbl))
    set.seed(42)
    rf <- randomForest(label ~ feat1 + feat2, data = df, ntree = 200, importance = TRUE)
    oob <- rf$err.rate[nrow(rf$err.rate), "OOB"]
    imp <- importance(rf)
    top_feat <- rownames(imp)[which.max(imp[, "MeanDecreaseGini"])]
    return(data.frame(
        oob_error_rate = oob,
        ntree = rf$ntree,
        most_important_feature = top_feat
    ))
$$ LANGUAGE plr;

-- 실행
SELECT * FROM plr_randomforest_train(
    (SELECT array_agg(feat1 ORDER BY id) FROM ds_rf_data),
    (SELECT array_agg(feat2 ORDER BY id) FROM ds_rf_data),
    (SELECT array_agg(label ORDER BY id) FROM ds_rf_data)
);


-- ================================================================
-- 7. MatrixModels — sparse 모델 매트릭스 기반 GLM
-- ================================================================

DROP TABLE IF EXISTS ds_matrixmodels_data;
CREATE TABLE ds_matrixmodels_data (
    id       SERIAL,
    category INTEGER,
    x_num    NUMERIC,
    y        NUMERIC
) DISTRIBUTED BY (id);

INSERT INTO ds_matrixmodels_data (category, x_num, y)
SELECT (i % 20) + 1 AS category, random() * 10 AS x_num,
       (i % 20) * 1.2 + (random()*10) * 0.5 + (random()*3) AS y
FROM generate_series(1, 500) AS i;

CREATE OR REPLACE FUNCTION plr_matrixmodels_glm(cat integer[], x_num float8[], y float8[])
RETURNS TABLE(n_coefficients integer, sparse_class text, deviance_val float8) AS $$
    library(MatrixModels)
    df <- data.frame(category = factor(cat), x_num = x_num, y = y)
    model <- glm4(y ~ category + x_num, data = df, sparse = TRUE)
    mm <- model.Matrix(y ~ category + x_num, data = df, sparse = TRUE)

    # deviance()가 S4 객체에서 실패하므로, slot을 직접 조회하거나
    # 잔차 기반으로 직접 계산
    dev_val <- tryCatch({
        model@deviance[["ML"]]
    }, error = function(e) {
        # slot 이름이 다를 경우를 대비한 fallback: 잔차제곱합으로 근사 계산
        sum(residuals(model)^2)
    })

    return(data.frame(
        n_coefficients = length(coef(model)),
        sparse_class   = class(mm)[1],
        deviance_val   = dev_val
    ))
$$ LANGUAGE plr;

-- 실행
SELECT * FROM plr_matrixmodels_glm(
    (SELECT array_agg(category ORDER BY id) FROM ds_matrixmodels_data),
    (SELECT array_agg(x_num    ORDER BY id) FROM ds_matrixmodels_data),
    (SELECT array_agg(y        ORDER BY id) FROM ds_matrixmodels_data)
);


-- ================================================================
-- 8. SparseM — 희소 행렬(sparse matrix) 연산
-- ================================================================

DROP TABLE IF EXISTS ds_sparse_data;
CREATE TABLE ds_sparse_data (
    row_idx INTEGER,
    col_idx INTEGER,
    val     NUMERIC
) DISTRIBUTED BY (row_idx);

INSERT INTO ds_sparse_data (row_idx, col_idx, val)
SELECT (random()*99)::int + 1, (random()*99)::int + 1,
       round((random()*10)::numeric, 2)
FROM generate_series(1, 300);   -- 100x100 중 약 3%만 비0

CREATE OR REPLACE FUNCTION plr_sparsem_test(rows integer[], cols integer[], vals float8[], dim integer)
RETURNS TABLE(density float8, nnz integer, row_sum_check float8) AS $$
    library(SparseM)
    dense_equiv <- matrix(0, dim, dim)
    for (i in seq_along(rows)) {
        dense_equiv[rows[i], cols[i]] <- dense_equiv[rows[i], cols[i]] + vals[i]
    }
    sp <- as.matrix.csr(dense_equiv)
    nnz_count <- length(sp@ra)
    dens <- nnz_count / (dim * dim)
    row_sums <- sp %*% rep(1, dim)
    return(data.frame(
        density = dens,
        nnz = nnz_count,
        row_sum_check = sum(as.matrix(row_sums))
    ))
$$ LANGUAGE plr;

-- 실행
SELECT * FROM plr_sparsem_test(
    (SELECT array_agg(row_idx) FROM ds_sparse_data),
    (SELECT array_agg(col_idx) FROM ds_sparse_data),
    (SELECT array_agg(val)     FROM ds_sparse_data),
    100
);


-- ================================================================
-- 9. coda — MCMC 체인 수렴 진단
-- ================================================================

DROP TABLE IF EXISTS ds_bayes_data;
CREATE TABLE ds_bayes_data (
    id SERIAL,
    x  NUMERIC,
    y  NUMERIC
) DISTRIBUTED BY (id);

INSERT INTO ds_bayes_data (x, y)
SELECT i AS x, 3 + 1.5 * i + (random()*4 - 2) AS y
FROM generate_series(1, 100) AS i;

CREATE OR REPLACE FUNCTION plr_coda_diagnostics(chain float8[])
RETURNS TABLE(effective_sample_size float8, geweke_z float8,
              chain_mean float8, chain_sd float8) AS $$
    library(coda)
    mc  <- mcmc(chain)
    ess <- effectiveSize(mc)
    gew <- geweke.diag(mc)
    return(data.frame(
        effective_sample_size = as.numeric(ess),
        geweke_z              = as.numeric(gew$z),
        chain_mean            = mean(chain),
        chain_sd              = sd(chain)
    ))
$$ LANGUAGE plr;

-- 실행 (MCMCpack의 slope 체인을 coda로 진단)
SELECT * FROM plr_coda_diagnostics(
    plr_mcmc_draws(
        (SELECT array_agg(x ORDER BY id) FROM ds_bayes_data),
        (SELECT array_agg(y ORDER BY id) FROM ds_bayes_data),
        5000
    )
);
-- 기대: geweke_z가 -2~2 사이면 체인 수렴 양호


-- ================================================================
-- 10. ggplot2 — 그래픽 렌더링 없이 "계산 결과"만 검증
--     (그래픽 디바이스/X11 미사용: ggplot_build로 통계 레이어만 추출)
-- ================================================================
%%sql
DROP TABLE IF EXISTS ds_regression_data;
CREATE TABLE ds_regression_data (
    id       SERIAL,
    ad_spend NUMERIC,
    sales    NUMERIC
) DISTRIBUTED BY (id);

INSERT INTO ds_regression_data (ad_spend, sales)
SELECT x AS ad_spend, 5 + 2.3 * x + (random() * 10 - 5) AS sales
FROM generate_series(1, 200) AS x;

CREATE OR REPLACE FUNCTION plr_ggplot_stat_check(x float8[], y float8[])
RETURNS TABLE(layer_name text, n_points integer, fitted_min float8, fitted_max float8) AS $$
    library(ggplot2)
    df <- data.frame(x = x, y = y)

    # 실제 화면 출력/파일 저장 없이, ggplot 객체의 통계 계산 결과만 추출
    p <- ggplot(df, aes(x = x, y = y)) +
         geom_point() +
         geom_smooth(method = "lm", se = FALSE)

    built <- ggplot_build(p)          # 그래픽 디바이스를 열지 않고 내부 계산만 수행
    smooth_layer <- built$data[[2]]   # geom_smooth 계산 결과 (fitted line 좌표)

    return(data.frame(
        layer_name  = "geom_smooth_fit",
        n_points    = nrow(smooth_layer),
        fitted_min  = min(smooth_layer$y),
        fitted_max  = max(smooth_layer$y)
    ))
$$ LANGUAGE plr;

-- 실행 (X11/그래픽 디바이스 오픈 없이 ggplot2의 내부 통계 계산만 검증)
SELECT * FROM plr_ggplot_stat_check(
    (SELECT array_agg(ad_spend ORDER BY id) FROM ds_regression_data),
    (SELECT array_agg(sales    ORDER BY id) FROM ds_regression_data)
);
-- 기대: fitted_min/max가 sales 데이터의 대략적인 범위와 일치 → ggplot2 정상 동작 확인
-- (실제 이미지 파일이 필요하면 로컬 R/Jupyter에서 별도로 렌더링하는 것을 권장)


-- ================================================================
-- 전체 실행 순서 요약
-- ================================================================
-- 1) CREATE EXTENSION plr;
-- 2) plr_packages_check_table() 으로 8개 패키지 설치 여부 확인
-- 3) 섹션 1~10 순서대로 테이블 생성 → 함수 생성 → SELECT 실행
-- 4) 기대 결과 가이드:
--    - t-test        : p_value < 0.05 (두 그룹 평균 차이 유의)
--    - regression       : slope ≈ 2.3
--    - dplyr          : 지역별 평균 판매액 내림차순 정렬 결과
--    - MCMCpack       : slope 사후평균 ≈ 1.5
--    - lme4           : fixed_slope ≈ 3, group_variance > 0
--    - randomForest   : oob_error_rate 낮음, 클래스 3개 잘 구분
--    - MatrixModels   : sparse_class = "dgCMatrix"
--    - SparseM        : density ≈ 0.03
--    - coda           : geweke_z가 -2~2 사이
--    - ggplot2        : fitted_min/max가 sales 데이터 범위와 일치
-- ================================================================

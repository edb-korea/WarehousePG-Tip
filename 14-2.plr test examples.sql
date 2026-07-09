-- ================================================================
-- Greenplum PL/R 고급 패키지 테스트 스크립트
-- 대상 패키지: MCMCpack, lme4, ggplot2, randomForest,
--             MatrixModels, SparseM, coda
--
-- 사전 요구사항: 아래 R 패키지들이 모든 세그먼트 호스트의 R 라이브러리 경로에
-- 설치되어 있어야 합니다.
--   R -e 'install.packages(c("MCMCpack","lme4","ggplot2","randomForest",
--                            "MatrixModels","SparseM","coda"))'
-- ================================================================

CREATE EXTENSION IF NOT EXISTS plr;

-- 설치 확인용
CREATE OR REPLACE FUNCTION plr_packages_check()
RETURNS text AS $$
    pkgs <- c("MCMCpack","lme4","ggplot2","randomForest",
              "MatrixModels","SparseM","coda")
    installed <- sapply(pkgs, requireNamespace, quietly = TRUE)
    return(paste(names(installed), installed, sep="=", collapse=", "))
$$ LANGUAGE plr;

-- SELECT plr_packages_check();


-- ================================================================
-- 1. MCMCpack — 베이지안 선형 회귀 (MCMC 샘플링)
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

-- MCMCregress로 사후분포 샘플링 후 posterior mean/quantile 요약
CREATE OR REPLACE FUNCTION plr_mcmc_regression(x float8[], y float8[], n_iter integer)
RETURNS TABLE(param text, post_mean float8, post_sd float8,
              ci_2_5 float8, ci_97_5 float8) AS $$
    library(MCMCpack)
    df <- data.frame(x = x, y = y)
    set.seed(1)
    post <- MCMCregress(y ~ x, data = df, mcmc = n_iter, burnin = 1000,
                         verbose = 0)
    s <- summary(post)
    stat <- s$statistics
    q    <- s$quantiles
    return(data.frame(
        param    = rownames(stat)[1:2],
        post_mean = stat[1:2, "Mean"],
        post_sd   = stat[1:2, "SD"],
        ci_2_5    = q[1:2, "2.5%"],
        ci_97_5   = q[1:2, "97.5%"]
    ))
$$ LANGUAGE plr;

-- 실행 (5000회 반복 샘플링)
SELECT * FROM plr_mcmc_regression(
    (SELECT array_agg(x ORDER BY id) FROM ds_bayes_data),
    (SELECT array_agg(y ORDER BY id) FROM ds_bayes_data),
    5000
);

-- 원시 posterior 샘플(slope 체인)만 배열로 뽑아주는 함수 (coda 테스트에서 재사용)
CREATE OR REPLACE FUNCTION plr_mcmc_draws(x float8[], y float8[], n_iter integer)
RETURNS float8[] AS $$
    library(MCMCpack)
    df <- data.frame(x = x, y = y)
    set.seed(1)
    post <- MCMCregress(y ~ x, data = df, mcmc = n_iter, burnin = 1000,
                         verbose = 0)
    return(as.numeric(post[, "x"]))
$$ LANGUAGE plr;


-- ================================================================
-- 2. lme4 — 혼합효과 모델 (그룹별 임의절편)
-- ================================================================

DROP TABLE IF EXISTS ds_mixed_data;
CREATE TABLE ds_mixed_data (
    id       SERIAL,
    school   INTEGER,
    hours    NUMERIC,
    score    NUMERIC
) DISTRIBUTED BY (id);

INSERT INTO ds_mixed_data (school, hours, score)
SELECT
    s AS school,
    h AS hours,
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
        fixed_intercept    = fe[1],
        fixed_slope        = fe[2],
        group_variance     = vc$vcov[vc$grp == "grp"],
        residual_variance  = vc$vcov[vc$grp == "Residual"]
    ))
$$ LANGUAGE plr;

-- 실행
SELECT * FROM plr_lmer_test(
    (SELECT array_agg(school ORDER BY id) FROM ds_mixed_data),
    (SELECT array_agg(hours  ORDER BY id) FROM ds_mixed_data),
    (SELECT array_agg(score  ORDER BY id) FROM ds_mixed_data)
);


-- ================================================================
-- 3. ggplot2 — 산점도 + 회귀선 그래프를 PNG(bytea)로 반환
-- ================================================================

CREATE OR REPLACE FUNCTION plr_ggplot_scatter(x float8[], y float8[])
RETURNS bytea AS $$
    library(ggplot2)
    df <- data.frame(x = x, y = y)
    p <- ggplot(df, aes(x = x, y = y)) +
         geom_point(alpha = 0.5, color = "steelblue") +
         geom_smooth(method = "lm", color = "darkred") +
         labs(title = "PL/R + ggplot2 Test", x = "X", y = "Y") +
         theme_minimal()

    tmpfile <- tempfile(fileext = ".png")
    ggsave(tmpfile, plot = p, width = 6, height = 4, dpi = 100)
    raw_data <- readBin(tmpfile, what = "raw", n = file.info(tmpfile)$size)
    unlink(tmpfile)
    return(raw_data)
$$ LANGUAGE plr;

DROP TABLE IF EXISTS ds_plot_output;
CREATE TABLE ds_plot_output (
    id      SERIAL,
    png_img BYTEA
) DISTRIBUTED BY (id);

INSERT INTO ds_plot_output (png_img)
SELECT plr_ggplot_scatter(
    (SELECT array_agg(x ORDER BY id) FROM ds_bayes_data),
    (SELECT array_agg(y ORDER BY id) FROM ds_bayes_data)
);

-- 클라이언트에서 PNG 추출 예시 (애플리케이션 코드 / psql \copy 등으로 디코딩 후 저장)
-- 예: psycopg2 등에서 SELECT png_img FROM ds_plot_output WHERE id=1; 결과를 파일로 write


-- ================================================================
-- 4. randomForest — 분류 모델 (2개 피처, 3개 클래스)
-- ================================================================

DROP TABLE IF EXISTS ds_rf_data;
CREATE TABLE ds_rf_data (
    id      SERIAL,
    feat1   NUMERIC,
    feat2   NUMERIC,
    label   TEXT
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
    oob  <- rf$err.rate[nrow(rf$err.rate), "OOB"]
    imp  <- importance(rf)
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

-- 새 데이터 포인트 예측 함수
CREATE OR REPLACE FUNCTION plr_randomforest_predict(
    f1 float8[], f2 float8[], lbl text[],
    new_f1 float8, new_f2 float8
) RETURNS text AS $$
    library(randomForest)
    df <- data.frame(feat1 = f1, feat2 = f2, label = factor(lbl))
    set.seed(42)
    rf <- randomForest(label ~ feat1 + feat2, data = df, ntree = 200)
    pred <- predict(rf, newdata = data.frame(feat1 = new_f1, feat2 = new_f2))
    return(as.character(pred))
$$ LANGUAGE plr;

-- SELECT plr_randomforest_predict(
--     (SELECT array_agg(feat1 ORDER BY id) FROM ds_rf_data),
--     (SELECT array_agg(feat2 ORDER BY id) FROM ds_rf_data),
--     (SELECT array_agg(label ORDER BY id) FROM ds_rf_data),
--     3.0, 3.0
-- );


-- ================================================================
-- 5. MatrixModels — 대규모 회귀용 모델 매트릭스/GLM (sparse 지원)
-- ================================================================

DROP TABLE IF EXISTS ds_matrixmodels_data;
CREATE TABLE ds_matrixmodels_data (
    id       SERIAL,
    category INTEGER,
    x_num    NUMERIC,
    y        NUMERIC
) DISTRIBUTED BY (id);

INSERT INTO ds_matrixmodels_data (category, x_num, y)
SELECT
    (i % 20) + 1 AS category,
    random() * 10 AS x_num,
    (i % 20) * 1.2 + (random()*10) * 0.5 + (random()*3) AS y
FROM generate_series(1, 500) AS i;

CREATE OR REPLACE FUNCTION plr_matrixmodels_glm(cat integer[], x_num float8[], y float8[])
RETURNS TABLE(n_coefficients integer, sparse_class text, deviance float8) AS $$
    library(MatrixModels)
    df <- data.frame(category = factor(cat), x_num = x_num, y = y)
    model <- glm4(y ~ category + x_num, data = df, sparse = TRUE)
    mm <- model.Matrix(y ~ category + x_num, data = df, sparse = TRUE)
    return(data.frame(
        n_coefficients = length(coef(model)),
        sparse_class   = class(mm)[1],
        deviance       = deviance(model)
    ))
$$ LANGUAGE plr;

-- 실행
SELECT * FROM plr_matrixmodels_glm(
    (SELECT array_agg(category ORDER BY id) FROM ds_matrixmodels_data),
    (SELECT array_agg(x_num    ORDER BY id) FROM ds_matrixmodels_data),
    (SELECT array_agg(y        ORDER BY id) FROM ds_matrixmodels_data)
);


-- ================================================================
-- 6. SparseM — 희소 행렬(sparse matrix) 연산
-- ================================================================

DROP TABLE IF EXISTS ds_sparse_data;
CREATE TABLE ds_sparse_data (
    row_idx INTEGER,
    col_idx INTEGER,
    val     NUMERIC
) DISTRIBUTED BY (row_idx);

-- 전체 10000칸(100x100) 중 약 300개(3%)만 비0 값으로 채움
INSERT INTO ds_sparse_data (row_idx, col_idx, val)
SELECT
    (random()*99)::int + 1,
    (random()*99)::int + 1,
    round((random()*10)::numeric, 2)
FROM generate_series(1, 300);

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
    ones_vec <- rep(1, dim)
    row_sums <- sp %*% ones_vec
    return(data.frame(
        density = dens,
        nnz = nnz_count,
        row_sum_check = sum(as.matrix(row_sums))
    ))
$$ LANGUAGE plr;

-- 실행 (100x100 행렬)
SELECT * FROM plr_sparsem_test(
    (SELECT array_agg(row_idx) FROM ds_sparse_data),
    (SELECT array_agg(col_idx) FROM ds_sparse_data),
    (SELECT array_agg(val)     FROM ds_sparse_data),
    100
);


-- ================================================================
-- 7. coda — MCMC 체인 수렴 진단 (MCMCpack 결과 재사용)
-- ================================================================

CREATE OR REPLACE FUNCTION plr_coda_diagnostics(chain float8[])
RETURNS TABLE(effective_sample_size float8, geweke_z float8,
              chain_mean float8, chain_sd float8) AS $$
    library(coda)
    mc <- mcmc(chain)
    ess <- effectiveSize(mc)
    gew <- geweke.diag(mc)
    return(data.frame(
        effective_sample_size = as.numeric(ess),
        geweke_z              = as.numeric(gew$z),
        chain_mean            = mean(chain),
        chain_sd              = sd(chain)
    ))
$$ LANGUAGE plr;

-- 실행: MCMCpack에서 뽑은 slope 파라미터 체인을 coda로 진단
SELECT * FROM plr_coda_diagnostics(
    plr_mcmc_draws(
        (SELECT array_agg(x ORDER BY id) FROM ds_bayes_data),
        (SELECT array_agg(y ORDER BY id) FROM ds_bayes_data),
        5000
    )
);

-- 해석 기준:
--   effective_sample_size가 전체 iteration 수(5000)에 가까울수록 체인 혼합이 좋음
--   geweke_z가 대략 -2 ~ +2 사이면 체인이 수렴했다고 판단 (표준정규분포 기준)


-- ================================================================
-- 전체 실행 순서 요약
-- ================================================================
-- 1) CREATE EXTENSION plr;                 (최초 1회, 세그먼트에 R+패키지 설치 필요)
-- 2) plr_packages_check() 로 패키지 설치 여부 확인
-- 3) 섹션 1~7 순서대로 테이블 생성 → 함수 생성 → SELECT 실행
-- 4) 기대 결과 가이드:
--    - MCMCpack : slope 사후평균이 실제값 1.5 근처
--    - lme4     : fixed_slope가 3 근처, group_variance > 0
--    - ggplot2  : ds_plot_output에 PNG 바이너리 1행 저장됨
--    - randomForest : oob_error_rate가 낮고(0에 가까움), 클래스 3개 잘 구분
--    - MatrixModels : sparse_class가 "dgCMatrix" 등으로 나오면 정상
--    - SparseM  : density가 대략 0.03(3%) 근처로 나와야 정상
--    - coda     : geweke_z가 -2~2 사이면 MCMC 체인 수렴 양호
-- ================================================================

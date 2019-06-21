functions {
  real p2l_real (real x) { // coverts scalar from probit to logit scale
    real y;
    y = 0.07056 * pow(x, 3) + 1.5976 * x;
    return y;
  }
  vector p2l_vector (vector x) { // coverts vector from probit to logit scale
    vector[num_elements(x)] y;
    for (i in 1:num_elements(x)) {
      y[i] = 0.07056 * pow(x[i], 3) + 1.5976 * x[i];
    }
    return y;
  }
}
data {
  int<lower=1> T;		  // number of years
  int<lower=1> G;		  // number of covariate groups
  int<lower=1> Q;		  // number of items/questions
  int<lower=1> D;		  // number of latent dimensions
  int<lower=1> K;		  // max number of answer options
  int<lower=1> P;		  // number of hierarchical predictors
  real<lower=0> SSSS[T, G, Q, K]; // number of responses (possibly non-integer)
  real beta_sign[Q, D];		  // sign restrictions on betas
  int unused_cut[Q, (K-1)];	  // indicates categories with no responses
  int<lower=0,upper=1> evolving_alpha; // indicates whether alpha should evolve
  int<lower=0> N_nonzero;	       // number of non-zero elements of SSSS
  matrix<lower=0,upper=1>[G, P] XX;    // hier. preds. (includ. intercept)
  int<lower=0,upper=1> cross_smooth;       // indicator for hierarchical model
  int<lower=0,upper=1> time_smooth;     // indicator for no over-time smoothing
}
transformed data {
  matrix[G, P] XX_ctr;
  /* matrix[G, P-1] Q_ast; */
  /* matrix[P-1, P-1] R_ast; */
  /* matrix[P-1, P-1] R_ast_inverse; */
  for (p in 1:P) {
    XX_ctr[1:G, p] = XX[1:G, p] - mean(XX[1:G, p]); // for interpretability
  }
  // thin and scale the QR decomposition
  /* Q_ast = qr_Q(XX[, 2:P])[, 1:(P-1)] * sqrt(G - 1); /\* no intercept *\/ */
  /* R_ast = qr_R(XX[, 2:P])[1:(P-1), ] / sqrt(G - 1); */
  /* R_ast_inverse = inverse(R_ast); */
}
parameters {
  real raw_bar_theta_N01[T, G, D]; // group means (pre-normalized, N(0,1) scale)
  ordered[K-1] raw_alpha[Q];	   // thresholds (difficulty)
  vector[Q] alpha_drift[T];	   // question-specific drift
  real beta_free[D, Q];		   // discrimination (unconstrained)
  real<upper=0> beta_neg[D, Q];	   // discrimination (negative)
  real<lower=0> beta_pos[D, Q];	   // discrimination (positive)
  vector<lower=0>[D] sd_theta_N01; // standard normal
  vector<lower=0>[D] sd_theta_IG;  // inverse-gamma
  vector<lower=0>[D] sd_raw_bar_theta_evolve_N01; // standard normal
  vector<lower=0>[D] sd_raw_bar_theta_evolve_IG;  // inverse-gamma
  real<lower=0> sd_alpha_evolve_N01;	  // standard normal
  real<lower=0> sd_alpha_evolve_IG;       // inverse-gamma
  real<lower=0> B_cut;			  // slope for cutpoint prior
  /* new */
  vector[T] raw_xi;				  // year-specific intercept
  vector[T] delta_tbar;			  // lag coefficient
  vector[P-1] raw_gamma[T];			  // hierarchical parameters
}
transformed parameters {
  // Declarations
  real raw_bar_theta[T, G, D]; // group means (pre-normalized)
  real bar_theta[T, G, D];     // group means (normalized)
  matrix[Q, D] beta;	       // discrimination
  ordered[K-1] alpha[T, Q];    // thresholds (difficulty)
  vector[D] sd_theta;	       // within-group SD of theta
  vector[D] sd_raw_bar_theta_evolve;   // transition SD of theta
  real sd_alpha_evolve;	       // transition SD of alpha
  cov_matrix[D] Sigma_theta;   // diagonal matrix of within-group variances
  vector[D] mean_raw_bar_theta;
  vector[D] sd_raw_bar_theta;
  // Assignments
  sd_theta = sd_theta_N01 .* sqrt(sd_theta_IG); // sd_theta ~ cauchy(0, 1);
  sd_raw_bar_theta_evolve =
    sd_raw_bar_theta_evolve_N01 .* sqrt(sd_raw_bar_theta_evolve_IG); // ditto
  sd_alpha_evolve = sd_alpha_evolve_N01 * sqrt(sd_alpha_evolve_IG);  // ditto
  Sigma_theta = diag_matrix(sd_theta .* sd_theta);
  for (t in 1:T) {
    for (q in 1:Q) {
      for (k in 1:(K-1)) {
        if (evolving_alpha == 0) {
	  alpha[t, q][k] = raw_alpha[q, k] + alpha_drift[1][q]; // copy first period
	}
	if (evolving_alpha == 1) {
	  // implies alpha[t,q][k] ~ N(alpha[t-1, q][k], sd_alpha_evolve)
	  alpha[t, q][k] = raw_alpha[q, k] + alpha_drift[t][q];
	}
      }
    }
    if (t == 1 || time_smooth == 0) {
      for (g in 1:G) {
	for (d in 1:D) {
	  /* // implies raw_bar_theta[t, g, d] ~ N(0, 1) */
	  /* raw_bar_theta[t, g, d] = raw_bar_theta_N01[t, g, d]; */
	  // implies raw_bar_theta[t, g, d] ~ N(raw_xi[t] + XX_ctr * raw_gamma[t], 1)
	  raw_bar_theta[t, g, d] = raw_xi[t]
	    + XX_ctr[g, 2:P] * raw_gamma[t][1:(P-1)] * cross_smooth
	    + raw_bar_theta_N01[t, g, d];
	  /* ALTERNATIVELY (QR) */
	  /* raw_bar_theta[t, g, d] = raw_xi[t] + Q_ast[g, 1:(P-1)] * raw_gamma[t][1:(P-1)] */
	  /*   + raw_bar_theta_N01[t, g, d];  */
	}
      }
    }
    if (t > 1 && time_smooth == 1) {
      for (g in 1:G) {
	for (d in 1:D) {
	  // implies raw_bar_theta[t] ~
	  // N(raw_xi[t] + delta_tbar[t] * raw_bar_theta[t-1],
	  // sd_raw_bar_theta_evolve)
	  raw_bar_theta[t, g, d] = raw_xi[t]
	    + delta_tbar[t] * (raw_bar_theta[t-1, g, d] -
			       mean(raw_bar_theta[t-1, 1:G, d])) // centered
	    + sd_raw_bar_theta_evolve[d] * raw_bar_theta_N01[t, g, d]; 
	}
      }
    }
  }
  // Identify location and scale
  for (d in 1:D) {
    mean_raw_bar_theta[d] = mean(to_matrix(raw_bar_theta[1:T, 1:G, d]));
    sd_raw_bar_theta[d] = sd(to_matrix(raw_bar_theta[1:T, 1:G, d]));
    for (t in 1:T) {
      for (g in 1:G) {
	bar_theta[t, g, d] = (raw_bar_theta[t, g, d] - mean_raw_bar_theta[d])
	  ./ sd_raw_bar_theta[d];
      }
    }
  }
  // Identify polarity
  for (q in 1:Q) {
    for (d in 1:D) {
      if (beta_sign[q, d] == 0) {
	beta[q, d] = beta_free[d, q];
      }
      if (beta_sign[q, d] < 0) {
	beta[q, d] = beta_neg[d, q];
      }
      if (beta_sign[q, d] > 0) {
	beta[q, d] = beta_pos[d, q];
      }
    }
  }
}
model {
  vector[N_nonzero] loglike_summands; // to store log-likelihood for summation
  int SSSS_pos = 0;
  // Priors
  for (q in 1:Q) {
    real used_cutp = K-1 - sum( unused_cut[q, 1:(K-1)] );
    real adjust_int = ( used_cutp / 2 ) + .5;
    real adjust_slp = 1;
    if (used_cutp > 1){
      adjust_slp = used_cutp - 1;
    }
    for (k in 1:(K-1)) {
      real priormean = 100 * unused_cut[q, k] + B_cut / adjust_slp * (k - adjust_int);
      raw_alpha[q][k] ~ normal(priormean, 1);
    }
    for (t in 1:T) {
      if (t == 1 || time_smooth == 0) {
	alpha_drift[t][q] ~ normal(0, 1);
      }
      if (t > 1 && time_smooth == 1) {
	alpha_drift[t][q] ~ normal(alpha_drift[t-1][q], sd_alpha_evolve);
      }
    }
  }
  to_array_1d(raw_bar_theta_N01[1:T, 1:G, 1:D]) ~ normal(0, 1);
  to_array_1d(beta_free[1:D, 1:Q]) ~ normal(0, 10);
  to_array_1d(beta_neg[1:D, 1:Q]) ~ normal(0, 10);
  to_array_1d(beta_pos[1:D, 1:Q]) ~ normal(0, 10);
  sd_theta_N01 ~ normal(0, 1);		    // sd_theta ~ cauchy(0, 1); 
  sd_theta_IG ~ inv_gamma(0.5, 0.5);	    // ditto
  sd_raw_bar_theta_evolve_N01 ~ normal(0, 1);	    // ditto
  sd_raw_bar_theta_evolve_IG ~ inv_gamma(0.5, 0.5); // ditto
  sd_alpha_evolve_N01 ~ normal(0, 1);	    // ditto
  sd_alpha_evolve_IG ~ inv_gamma(0.5, 0.5); // ditto
  B_cut ~ normal(0, 1);
  /* new */
  for (t in 1:T) {
    if (t == 1 || time_smooth == 0) {
      delta_tbar[t] ~ normal(.5, 1);
      raw_xi[t] ~ normal(0, 10);
      raw_gamma[t] ~ normal(0, 1);
    }
    if (t > 1 && time_smooth == 1) {
      /* TODO: make sd paramters */
      delta_tbar[t] ~ normal(delta_tbar[t-1], .1);
      raw_xi[t] ~ normal(raw_xi[t-1], 10);
      raw_gamma[t] ~ normal(raw_gamma[t-1], .1);
    }
  }
  // Likelihood
  for (t in 1:T) {
    for (q in 1:Q) { 
      real z_denom =
      	  sqrt(1 + quad_form(Sigma_theta[1:D, 1:D], to_vector(beta[q][1:D])));
      vector[K-1] cut = p2l_vector(alpha[t, q][1:(K-1)] / z_denom);
      for (g in 1:G) {
        for (k in 1:K) {
	  if (SSSS[t, g, q, k] > 0) {
	    real eta;
	    SSSS_pos += 1;
	    eta = p2l_real(beta[q][1:D] * to_vector(bar_theta[t, g, 1:D])
			   / z_denom);
	    loglike_summands[SSSS_pos] =
	      SSSS[t, g, q, k] * ordered_logistic_lpmf(k | eta, cut);
	  }
        }
      }
    }
  }
  target += sum(loglike_summands);
}
generated quantities {
  vector[D] sd_bar_theta_evolve =
    sd_raw_bar_theta_evolve[1:D] ./ sd_raw_bar_theta;
  real<lower=0,upper=1> PI[T, G, Q, K];
  vector[T] xi;
  vector[P-1] gamma[T];			  
  for (t in 1:T) {
    /* convert to bar_theta scale (NEED TO ACCOUNT FOR DIMENSIONALITY LATER) */
    for (d in 1:D) {
      xi[t] = (raw_xi[t] - mean_raw_bar_theta[d]) ./ sd_raw_bar_theta[d];
      gamma[t, 1:(P-1)] = raw_gamma[t, 1:(P-1)] ./ sd_raw_bar_theta[d];
    }
    for (g in 1:G) {
      for (q in 1:Q) {
	real z_denom =
      	  sqrt(1 + quad_form(Sigma_theta[1:D, 1:D], to_vector(beta[q][1:D])));
  	for (k in 1:K) {
  	  if (k == 1) {
  	    PI[t, g, q, k] = 1 -
  	      Phi_approx((beta[q][1:D] * to_vector(bar_theta[t, g, 1:D]) -
  			  alpha[t, q][k]) / z_denom);
  	  }
  	  if (k > 1 && k < K) {
  	    PI[t, g, q, k] =
  	      Phi_approx((beta[q][1:D] * to_vector(bar_theta[t, g, 1:D]) -
  			  alpha[t, q][k - 1]) / z_denom) -
  	      Phi_approx((beta[q][1:D] * to_vector(bar_theta[t, g, 1:D]) -
  			  alpha[t, q][k]) / z_denom);
  	  } if (k == K) {
  	    PI[t, g, q, k] =
  	      Phi_approx((beta[q][1:D] * to_vector(bar_theta[t, g, 1:D]) -
  			  alpha[t, q][k - 1]) / z_denom);
  	  }
  	}
      }
    }
  }
}

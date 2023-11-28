package slate.filters;

import com.auth0.jwt.JWT;
import com.auth0.jwt.algorithms.Algorithm;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.Collections;

/**
 * Filter for bearer authorization
 */
@Component
public class JWTAuthorizationFilter extends OncePerRequestFilter {

    private static final Logger logger = LoggerFactory.getLogger(JWTAuthorizationFilter.class);

    private static final String secret = System.getenv("WEBHOOK_SECRET");
    private static final String SCHEME_PART = "Bearer ";

    public static final String DUMMY_AUTHORIZED_USERNAME = "authorized";
    public static final String DUMMY_AUTHORIZED_PASSWORD = "password";

    protected void doFilterInternal(
            HttpServletRequest req,
            HttpServletResponse res,
            FilterChain chain
    ) throws IOException, ServletException {
        String authorizationHeader = req.getHeader(HttpHeaders.AUTHORIZATION);
        if (authorizationHeader == null || !authorizationHeader.startsWith(SCHEME_PART)) {
            logger.info("no bearer token");
            chain.doFilter(req, res);
            return;
        }
        try {
            JWT.require(Algorithm.HMAC256(secret))
                    .build()
                    .verify(authorizationHeader.replace(SCHEME_PART, ""));
            UsernamePasswordAuthenticationToken authenticationToken =
                    new UsernamePasswordAuthenticationToken(DUMMY_AUTHORIZED_USERNAME, DUMMY_AUTHORIZED_PASSWORD, Collections.emptyList());
            SecurityContextHolder.getContext().setAuthentication(authenticationToken);
        } catch (Exception e) {
            logger.error("failed to authorize", e);
            SecurityContextHolder.clearContext();
        }
        chain.doFilter(req, res);
    }
}



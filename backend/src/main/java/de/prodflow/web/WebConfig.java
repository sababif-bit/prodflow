package de.prodflow.web;

import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.ViewControllerRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

/**
 * SPA fallback: the Angular router owns these URLs, so a reload or a bookmark must be answered with index.html (a forward, the URL
 * stays). Only the routes listed in FrontendRoutes are forwarded - an unknown path is NOT turned into index.html, so API typos
 * and probes still produce the normal 401/403/404 instead of a 200 HTML page.
 */
@Configuration
class WebConfig implements WebMvcConfigurer {

    @Override
    public void addViewControllers(ViewControllerRegistry registry) {
        for (String route : FrontendRoutes.SPA_ROUTES) {
            registry.addViewController(route).setViewName("forward:/index.html");
        }
    }
}

package com.aarav.cicd;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

@SpringBootApplication
@ConfigurationPropertiesScan
public class CicdDemoAppApplication {

	public static void main(String[] args) {
		SpringApplication.run(CicdDemoAppApplication.class, args);
	}

}

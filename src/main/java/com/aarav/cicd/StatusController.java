package com.aarav.cicd;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.ResponseBody;

@Controller
public class StatusController {

	private final StatusService statusService;

	public StatusController(StatusService statusService) {
		this.statusService = statusService;
	}

	@GetMapping("/")
	public String statusPage(Model model) {
		model.addAttribute("info", statusService.currentStatus());
		return "index";
	}

	/** JSON version of the page, used by the pipeline's smoke test. */
	@GetMapping("/api/status")
	@ResponseBody
	public DeploymentStatus statusApi() {
		return statusService.currentStatus();
	}

}

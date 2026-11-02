// CI/CD pipeline for cicd-demo-app (Jenkins Multibranch Pipeline).
//
// Every branch and pull request:  Checkout -> Secret Scan -> Build -> Test -> Package
// main only (after a merge):       Docker Build -> Image Scan -> Push -> Deploy -> Verify
//
// Jenkins credentials used (added once in Manage Jenkins > Credentials):
//   acr-credentials  username/password for Azure Container Registry
//   aks-kubeconfig   secret file: kubeconfig limited to the cicd-demo namespace
// ACR_LOGIN_SERVER is a global variable set by ansible/jenkins.yml.

pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
    }

    environment {
        APP_NAME  = 'cicd-demo-app'
        NAMESPACE = 'cicd-demo'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.GIT_SHORT   = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
                    env.APP_VERSION = sh(script: './mvnw -q -B help:evaluate -Dexpression=project.version -DforceStdout',
                                         returnStdout: true).trim()
                    env.IMAGE       = "${env.ACR_LOGIN_SERVER}/${env.APP_NAME}:${env.APP_VERSION}-${env.GIT_SHORT}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} v${env.APP_VERSION} (${env.GIT_SHORT})"
                }
            }
        }

        stage('Secret Scan') {
            steps {
                // Fails the build if a password, key or token is found anywhere in the Git history
                sh 'gitleaks git --redact --verbose --no-banner --report-format json --report-path gitleaks-report.json .'
            }
            post {
                always {
                    archiveArtifacts artifacts: 'gitleaks-report.json', allowEmptyArchive: true
                }
            }
        }

        stage('Build') {
            steps {
                sh './mvnw -B -ntp compile'
            }
        }

        stage('Test') {
            steps {
                sh './mvnw -B -ntp test'
            }
            post {
                always {
                    junit 'target/surefire-reports/*.xml'
                }
            }
        }

        stage('Package') {
            steps {
                sh './mvnw -B -ntp package -DskipTests'
                archiveArtifacts artifacts: 'target/cicd-demo-app.jar', fingerprint: true
            }
        }

        stage('Docker Build') {
            when { branch 'main' }
            steps {
                sh 'docker build --pull -t "$IMAGE" .'
            }
        }

        stage('Image Scan') {
            when { branch 'main' }
            steps {
                // Report HIGH and CRITICAL issues, but only block the release on fixable CRITICAL ones.
                // (Secrets are already covered by Gitleaks; the first run downloads the vulnerability DBs.)
                sh '''
                    TRIVY="trivy image --scanners vuln --no-progress --skip-version-check --timeout 15m"
                    $TRIVY --severity HIGH,CRITICAL "$IMAGE"
                    $TRIVY --severity CRITICAL --ignore-unfixed --exit-code 1 "$IMAGE"
                '''
            }
        }

        stage('Push') {
            when { branch 'main' }
            steps {
                withCredentials([usernamePassword(credentialsId: 'acr-credentials',
                                                  usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS')]) {
                    sh '''
                        echo "$ACR_PASS" | docker login "$ACR_LOGIN_SERVER" -u "$ACR_USER" --password-stdin
                        docker push "$IMAGE"
                        docker logout "$ACR_LOGIN_SERVER"
                    '''
                }
            }
        }

        stage('Deploy') {
            when { branch 'main' }
            steps {
                withCredentials([file(credentialsId: 'aks-kubeconfig', variable: 'KUBECONFIG')]) {
                    sh '''
                        ansible-playbook ansible/deploy.yml \
                          -e app_image="$IMAGE" \
                          -e app_version="$APP_VERSION" \
                          -e build_number="$BUILD_NUMBER" \
                          -e git_commit="$GIT_SHORT"
                    '''
                }
            }
        }

        stage('Verify') {
            when { branch 'main' }
            steps {
                withCredentials([file(credentialsId: 'aks-kubeconfig', variable: 'KUBECONFIG')]) {
                    sh '''
                        kubectl -n "$NAMESPACE" rollout status deployment/"$APP_NAME" --timeout=60s
                        kubectl -n "$NAMESPACE" get deployment,pods,service -o wide
                        APP_IP=$(kubectl -n "$NAMESPACE" get service "$APP_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
                        curl -fsS "http://$APP_IP/api/status"
                        echo
                        echo "Application is live at http://$APP_IP"
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "Pipeline passed for ${env.BRANCH_NAME} (${currentBuild.displayName})"
        }
        failure {
            echo "Pipeline FAILED for ${env.BRANCH_NAME} - check the red stage above"
        }
        always {
            // Keep the VM's 30 GB disk from filling up with old images
            sh 'docker image prune -af --filter "until=48h" || true'
        }
    }
}
